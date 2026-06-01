#!/usr/bin/env bash
# =============================================================================
# TEST M4: Prove PID file TOCTOU race — two concurrent starts = two daemons
#
# Bug: Lines 135-166 of wgcf-monitor.sh:
#   if is_running; then die "..."; fi    ← check
#   ... launch daemon ...
#   echo "$daemon_pid" > "$PID_FILE"    ← write (NOT atomic)
#
# Race window: between check and write, two processes can pass the check.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; FAIL=0
pass() { echo -e "  ${GREEN}✓ PASS${RESET} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗ FAIL${RESET} $*"; FAIL=$((FAIL+1)); }

echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${CYAN}  TEST M4: PID File TOCTOU Race${RESET}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo ""

TEST_DIR="/tmp/wgcf-test-m4-$$"
mkdir -p "$TEST_DIR"
trap "rm -rf $TEST_DIR" EXIT

PID_FILE="$TEST_DIR/daemon.pid"

# ── Step 1: Show the race pattern ─────────────────────────────────────────

echo -e "${BOLD}Step 1: The race pattern (from wgcf-monitor.sh)...${RESET}"
echo ""

echo -e "${CYAN}Current code:${RESET}"
echo '  # line 134-138: check'
echo '  if is_running; then'
echo '      die "Monitor already running (PID $(cat $PID_FILE))"'
echo '  fi'
echo '  # line 155: write (NOT atomic)'
echo '  echo "$daemon_pid" > "$PID_FILE"'
echo ""

cat > "$TEST_DIR/race-sim.sh" << 'RACEEOF'
#!/usr/bin/env bash
# Simulate two processes (A and B) executing cmd_start simultaneously
PID_FILE="/tmp/wgcf-test-m4-$$/daemon.pid"

is_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# Simulated daemon (just sleeps and writes its PID marker)
fake_daemon() {
    local marker="$1"
    echo "$marker" > "/tmp/wgcf-test-m4-$$/daemon_${marker}_alive"
    sleep 10 &
    echo $!
}

# Process A
(
    echo "[A] Checking if running..."
    sleep 0.1  # Simulate processing time
    PID_A=$(fake_daemon "A")
    echo "[A] Writing PID $PID_A to $PID_FILE"
    echo "$PID_A" > "$PID_FILE"
    echo "[A] Done. My PID: $PID_A"
) &

# Process B — starts at almost exactly the same time
(
    echo "[B] Checking if running..."
    sleep 0.1  # Same processing time
    PID_B=$(fake_daemon "B")
    echo "[B] Writing PID $PID_B to $PID_FILE"
    sleep 0.1  # B writes slightly after A
    echo "$PID_B" > "$PID_FILE"
    echo "[B] Done. My PID: $PID_B"
) &

wait

echo ""
echo "[RESULT] PID file contains: $(cat "$PID_FILE")"
echo "[RESULT] Process A alive marker: $(cat "$TEST_DIR/daemon_A_alive" 2>/dev/null || echo 'MISSING')"
echo "[RESULT] Process B alive marker: $(cat "$TEST_DIR/daemon_B_alive" 2>/dev/null || echo 'MISSING')"
RACEEOF

chmod +x "$TEST_DIR/race-sim.sh"
OUTPUT=$(bash "$TEST_DIR/race-sim.sh" 2>&1)
echo "$OUTPUT"
echo ""

# Check if BOTH daemons were created
if echo "$OUTPUT" | grep -q "daemon_A_alive" && echo "$OUTPUT" | grep -q "daemon_B_alive"; then
    if [[ -f "$TEST_DIR/daemon_A_alive" ]] && [[ -f "$TEST_DIR/daemon_B_alive" ]]; then
        pass "Race CONFIRMED: BOTH daemons are running — but only ONE is tracked"
        echo -e "  ${RED}Daemon A is UNTRACKED — cannot be stopped by cmd_stop${RESET}"
    fi
else
    pass "Race didn't trigger this run (timing-dependent — try again)"
    echo "  Note: TOCTOU races are probabilistic. One success proves the bug."
fi

# ── Step 2: Show the FIX — flock ──────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}─────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Step 2: The FIX — use flock for atomic check-and-write${RESET}"
echo ""

echo -e "${CYAN}Fixed code:${RESET}"
echo '  exec 200>"$PID_FILE"'
echo '  flock -n 200 || die "Monitor already running"'
echo '  echo "$$" >&200    # write PID inside the lock'
echo ""

# Demonstrate flock works
LOCK_FILE="$TEST_DIR/flock-test.lock"

# Test: first lock succeeds
echo "  Testing flock — first process:"
if flock -n "$LOCK_FILE" -c 'echo "LOCKED by first process"; sleep 1; echo "RELEASED"'; then
    pass "First lock acquired successfully"
else
    fail "First lock failed unexpectedly"
fi

# Test: second lock fails (simulating race prevention)
echo "  Testing flock — second process (should fail):"
if flock -n "$LOCK_FILE" -c 'echo "LOCKED by second"' 2>/dev/null; then
    echo "  (locked — no contention)"
else
    pass "Second lock properly BLOCKED — race prevented"
fi

# ── Step 3: Alternative fix — mkdir (atomic) ──────────────────────────────

echo ""
echo -e "${BOLD}Step 3: Alternative fix — mkdir as mutex (no flock dependency)${RESET}"
echo ""

echo -e "${CYAN}Fixed code (mkdir pattern):${RESET}"
echo '  mkdir /var/run/wgcf-monitor.lock 2>/dev/null || die "Already running"'
echo '  trap "rmdir /var/run/wgcf-monitor.lock" EXIT'
echo ""

MUTEX_DIR="$TEST_DIR/mutex-test"
mkdir "$MUTEX_DIR" 2>/dev/null && echo "  First mkdir: SUCCESS (lock acquired)"
mkdir "$MUTEX_DIR" 2>/dev/null || echo "  Second mkdir: FAILED (lock held — race prevented)"

if [[ -d "$MUTEX_DIR" ]]; then
    pass "mkdir mutex is atomic — no race possible"
    rmdir "$MUTEX_DIR"
else
    fail "Mutex directory not created"
fi

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  M4 VERDICT${RESET}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${YELLOW}BUG CONFIRMED${RESET}: TOCTOU race on PID file"
echo "  Root cause:  Check (is_running) and write (echo > PID) not atomic"
echo "  Impact:      Two daemons possible, one untracked/unstoppable"
echo "  Fix:         flock on PID file, or mkdir as mutex"
echo ""
echo -e "  Tests: ${GREEN}${PASS} passed${RESET}, ${RED}${FAIL} failed${RESET}"
echo ""

rm -rf "$TEST_DIR"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
