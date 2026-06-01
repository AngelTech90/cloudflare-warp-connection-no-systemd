#!/usr/bin/env bash
# =============================================================================
# TEST C1: Prove that wgcf-monitor.sh daemon CANNOT start
#
# Bug: `nohup bash -c "source '${BASH_SOURCE[0]}'; run_daemon"` sources
# the entire script, which executes `main "$@"` at the bottom. With no args,
# main hits `*) usage; exit 0` and the daemon dies BEFORE run_daemon runs.
#
# This test creates a minimal mock that EXACTLY replicates the pattern.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; FAIL=0
pass() { echo -e "  ${GREEN}✓ PASS${RESET} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗ FAIL${RESET} $*"; FAIL=$((FAIL+1)); }

echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${CYAN}  TEST C1: Monitor Daemon Sourcing Bug${RESET}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo ""

# ── Step 1: Create a minimal mock that mimics wgcf-monitor.sh pattern ──────

MOCK_DIR="/tmp/wgcf-test-c1-$$"
mkdir -p "$MOCK_DIR"
trap "rm -rf $MOCK_DIR" EXIT

cat > "$MOCK_DIR/mock-monitor.sh" << 'MOCKEOF'
#!/usr/bin/env bash
# This mock has the EXACT same structure as wgcf-monitor.sh:
#   - run_daemon() defined as a function
#   - cmd_start() uses: nohup bash -c "source BASH_SOURCE; run_daemon"
#   - main() at the bottom (executed when sourced)
#   - main calls cmd_start when "start" arg is given

RUN_FILE="/tmp/wgcf-test-daemon-ran"

run_daemon() {
    echo "DAEMON_RUNNING" > "$RUN_FILE"
    # In real script: infinite loop runs FOREGROUND (keeps bash -c alive)
    while true; do sleep 1; done
}

cmd_start() {
    echo "[mock] Starting daemon using THE EXACT PATTERN from wgcf-monitor.sh..."
    # THIS IS THE BUG — line 150-153 of wgcf-monitor.sh:
    nohup bash -c "
        source '${BASH_SOURCE[0]}'
        run_daemon
    " > /dev/null 2>&1 &

    local daemon_pid=$!
    echo "[mock] Daemon PID: $daemon_pid"
    sleep 0.5

    if kill -0 "$daemon_pid" 2>/dev/null; then
        echo "DAEMON_ALIVE"
    else
        echo "DAEMON_DEAD"
    fi
}

main() {
    case "${1:-}" in
        start)  cmd_start ;;
        *)      echo "Usage: $0 start"; exit 0 ;;
    esac
}

# CRITICAL — this executes when the script is SOURCED:
main "$@"
MOCKEOF

chmod +x "$MOCK_DIR/mock-monitor.sh"

# ── Step 2: Run the mock ──────────────────────────────────────────────────

echo -e "${BOLD}Step 1: Running mock with current bug pattern...${RESET}"
echo ""

rm -f /tmp/wgcf-test-daemon-ran
RESULT=$(bash "$MOCK_DIR/mock-monitor.sh" start 2>&1)
echo "$RESULT"
echo ""

if echo "$RESULT" | grep -q "DAEMON_DEAD"; then
    pass "Daemon DIED immediately (BUG CONFIRMED)"
else
    fail "Daemon survived (unexpected — bug may not reproduce)"
fi

# ── Step 3: Prove WHY it dies ─────────────────────────────────────────────

echo ""
echo -e "${BOLD}Step 2: Tracing execution path to prove WHY it dies...${RESET}"
echo ""

# Create a traceable version
cat > "$MOCK_DIR/mock-trace.sh" << 'TRACEEOF'
#!/usr/bin/env bash
run_daemon() {
    echo "TRACE: run_daemon() EXECUTED — this should be the daemon's job"
}
main() {
    echo "TRACE: main() EXECUTED with arg='${1:-}'"
    case "${1:-}" in
        start) echo "TRACE: main() calling cmd_start..."; cmd_start ;;
        *)     echo "TRACE: main() NO ARGS — exiting with usage!"; exit 0 ;;
    esac
}
cmd_start() {
    echo "TRACE: cmd_start() — about to source script..."
    nohup bash -c "
        echo 'TRACE: Inside nohup bash -c, about to source...'
        source '${BASH_SOURCE[0]}'
        echo 'TRACE: After source — this line NEVER PRINTS with the bug'
        run_daemon
        echo 'TRACE: After run_daemon — this line NEVER PRINTS with the bug'
    " > /tmp/wgcf-trace-output.txt 2>&1 &
    sleep 1
    echo "TRACE: cmd_start() — done launching"
}
main "$@"
TRACEEOF

chmod +x "$MOCK_DIR/mock-trace.sh"
bash "$MOCK_DIR/mock-trace.sh" start 2>&1

echo ""
echo -e "${BOLD}Trace output from the daemon subprocess:${RESET}"
bat --style=plain /tmp/wgcf-trace-output.txt 2>/dev/null || cat /tmp/wgcf-trace-output.txt

echo ""
if grep -q "After source" /tmp/wgcf-trace-output.txt 2>/dev/null; then
    fail "Daemon reached 'After source' — bug NOT reproduced in trace"
else
    pass "Daemon NEVER reached 'run_daemon' — source kills it via main()"
fi

if grep -q "NO ARGS" /tmp/wgcf-trace-output.txt 2>/dev/null; then
    pass "Confirmed: main() executed with NO ARGS inside the sourced context"
fi

# ── Step 4: Show the FIX ──────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}─────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Step 3: Demonstrating the FIX...${RESET}"
echo ""

cat > "$MOCK_DIR/mock-fixed.sh" << 'FIXEOF'
#!/usr/bin/env bash
# FIX: Add a guard so main() only runs when EXECUTED, not when SOURCED

RUN_FILE="/tmp/wgcf-test-fix-ran"

run_daemon() {
    echo "DAEMON_RUNNING" > "$RUN_FILE"
    # Foreground loop keeps the daemon process alive
    while true; do sleep 1; done
}

cmd_start() {
    echo "[mock] Starting daemon with FIXED pattern..."
    nohup bash -c "
        source '${BASH_SOURCE[0]}'
        run_daemon
    " > /dev/null 2>&1 &

    local daemon_pid=$!
    echo "[mock] Daemon PID: $daemon_pid"
    sleep 0.5

    if kill -0 "$daemon_pid" 2>/dev/null; then
        echo "DAEMON_ALIVE"
    else
        echo "DAEMON_DEAD"
    fi
}

main() {
    case "${1:-}" in
        start)  cmd_start ;;
        *)      echo "Usage: $0 start"; exit 0 ;;
    esac
}

# THE FIX — only run main if executed directly, not when sourced:
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
FIXEOF

chmod +x "$MOCK_DIR/mock-fixed.sh"

rm -f /tmp/wgcf-test-fix-ran
RESULT_FIX=$(bash "$MOCK_DIR/mock-fixed.sh" start 2>&1)
echo "$RESULT_FIX"
echo ""

if echo "$RESULT_FIX" | grep -q "DAEMON_ALIVE"; then
    pass "Daemon STAYED ALIVE with the fix applied"
else
    fail "Daemon still died (fix didn't work)"
fi

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  C1 VERDICT${RESET}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${RED}BUG CONFIRMED${RESET}: wgcf-monitor.sh daemon NEVER runs"
echo "  Root cause: sourcing the script executes main() with no args"
echo "  Impact:     wgcf-monitor.sh 'start' was NEVER functional"
echo "  Fix:        Guard main() with [[ \"\${BASH_SOURCE[0]}\" == \"\${0}\" ]]"
echo ""
echo -e "  Tests: ${GREEN}${PASS} passed${RESET}, ${RED}${FAIL} failed${RESET}"
echo ""

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
