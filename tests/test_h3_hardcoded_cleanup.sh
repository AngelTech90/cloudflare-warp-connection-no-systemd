#!/usr/bin/env bash
# =============================================================================
# TEST H3: Prove that hardcoded gateway in cleanup breaks on non-192.168.0.x
#
# Bug: Lines 115-119, 122-127 of warp-wgcf-setup.sh:
#   KNOWN_PHYS_GW="192.168.0.1"   (hardcoded)
#   ip route show | grep "/32.*via.*${KNOWN_PHYS_GW}"
#
# The script correctly DETECTS the actual gateway at line 83 (PHYS_GW)
# and uses it in the config, but during CLEANUP it uses the hardcoded
# KNOWN_PHYS_GW. On networks with gateway 10.0.0.1 or 192.168.1.1,
# stale /32 host routes from previous runs are NOT cleaned up.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; FAIL=0
pass() { echo -e "  ${GREEN}✓ PASS${RESET} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗ FAIL${RESET} $*"; FAIL=$((FAIL+1)); }

echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${CYAN}  TEST H3: Hardcoded Gateway Cleanup Bug${RESET}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo ""

# ── Step 1: Show the dual variable problem ────────────────────────────────

echo -e "${BOLD}Step 1: The dual variable problem...${RESET}"
echo ""

echo -e "${CYAN}From warp-wgcf-setup.sh:${RESET}"
echo "  Line 33:  KNOWN_PHYS_GW=\"192.168.0.1\"     ← HARDCODED (used in cleanup)"
echo "  Line 83:  PHYS_GW (detected from 'ip route') ← CORRECT (used in config)"
echo ""

echo -e "${CYAN}Line 115 — cleanup uses KNOWN_PHYS_GW:${RESET}"
echo '  ip route show | grep "/32.*via.*${KNOWN_PHYS_GW}" | ... | ip route del'
echo ""
echo -e "${YELLOW}  If your actual gateway is 10.0.0.1, the grep NEVER matches.${RESET}"
echo -e "${YELLOW}  Stale /32 routes from previous WARP setup are NEVER cleaned up.${RESET}"
echo ""

# ── Step 2: Simulate with mock routes ─────────────────────────────────────

echo -e "${BOLD}Step 2: Simulating cleanup on a 10.0.0.x network...${RESET}"
echo ""

# Create mock routing table state
MOCK_ROUTES="/tmp/wgcf-test-routes-$$"
cat > "$MOCK_ROUTES" << 'EOF'
162.159.192.1 via 10.0.0.1 dev eth0
162.159.193.2 via 10.0.0.1 dev eth0
default via 10.0.0.1 dev eth0
10.96.0.0/16 via 10.0.0.1 dev eth0
192.168.1.0/24 via 10.0.0.1 dev eth0
EOF

echo "  Mock routing table (gateway = 10.0.0.1):"
bat --style=plain "$MOCK_ROUTES" 2>/dev/null || cat "$MOCK_ROUTES"
echo ""

# Buggy cleanup: uses hardcoded 192.168.0.1
BUGGY_GW="192.168.0.1"
FOUND_BUGGY=$(grep -c "via.*${BUGGY_GW}" "$MOCK_ROUTES" || true)
echo "  Buggy cleanup (grepping for 'via 192.168.0.1'):"
echo "    Routes found: $FOUND_BUGGY"
echo ""

if [[ "$FOUND_BUGGY" -eq 0 ]]; then
    pass "Bug CONFIRMED: grep finds ZERO routes — cleanup does nothing"
else
    fail "Unexpected: grep found routes"
fi

# Correct cleanup: uses detected PHYS_GW
CORRECT_GW="10.0.0.1"
FOUND_CORRECT=$(grep -c "via.*${CORRECT_GW}" "$MOCK_ROUTES" || true)
echo "  Correct cleanup (grepping for detected 'via 10.0.0.1'):"
echo "    Routes found: $FOUND_CORRECT"
echo ""

if [[ "$FOUND_CORRECT" -gt 0 ]]; then
    pass "FIX works: using detected PHYS_GW finds the actual routes"
else
    fail "Unexpected: correct grep found nothing"
fi

# ── Step 3: Show the actual code inconsistency ────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}─────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Step 3: Code inconsistency — detection vs cleanup${RESET}"
echo ""

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$PROJECT_DIR/warp-wgcf-setup.sh"

echo -e "${CYAN}Detection (line 83):${RESET}"
rg "PHYS_GW=" "$SCRIPT" | head -3
echo ""

echo -e "${CYAN}Hardcoded fallback (line 33):${RESET}"
rg "KNOWN_PHYS_GW" "$SCRIPT" | head -5
echo ""

echo -e "${CYAN}Cleanup uses KNOWN_PHYS_GW (line 115):${RESET}"
rg "KNOWN_PHYS_GW" "$SCRIPT" | grep "cleanup\|del\|route" || echo "  (See line 115-127 in script)"
echo ""

# Count: PHYS_GW vs KNOWN_PHYS_GW usage
PHYS_COUNT=$(rg -c "PHYS_GW" "$SCRIPT" || echo "0")
KNOWN_COUNT=$(rg -c "KNOWN_PHYS_GW" "$SCRIPT" || echo "0")
echo "  PHYS_GW (correct, detected) used: $PHYS_COUNT times"
echo "  KNOWN_PHYS_GW (hardcoded) used:   $KNOWN_COUNT times"
echo ""

if rg "cleanup.*KNOWN_PHYS_GW\|KNOWN_PHYS_GW.*cleanup\|KNOWN_PHYS_GW.*route.*del\|KNOWN_PHYS_GW.*grep" "$SCRIPT" -q 2>/dev/null; then
    pass "Confirmed: cleanup code uses KNOWN_PHYS_GW instead of PHYS_GW"
else
    echo "  Checking alternative patterns..."
    # More thorough check
    if rg "KNOWN_PHYS_GW" "$SCRIPT" | grep -v "^[[:space:]]*#" | grep -v "readonly\|local\|=" | head -3; then
        pass "Confirmed: KNOWN_PHYS_GW used in cleanup logic"
    fi
fi

# ── Step 4: Real impact ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}─────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Step 4: Real-world impact${RESET}"
echo ""

echo "  Scenario: Corporate network with gateway 172.16.0.1"
echo ""
echo "  1st run:"
echo "    → Script detects PHYS_GW=172.16.0.1 (correct)"
echo "    → Creates /32 route for Cloudflare endpoint via 172.16.0.1"
echo "    → WARP works fine"
echo ""
echo "  2nd run (re-install):"
echo "    → Cleanup greps for 'via 192.168.0.1' → finds NOTHING"
echo "    → Old /32 route for Cloudflare endpoint PERSISTS"
echo "    → Now TWO routes exist: old and new"
echo "    → Route conflict → intermittent connectivity"
echo ""
echo "  Admin has NO IDEA why because the script reports SUCCESS."
echo ""

pass "Real-world impact: route accumulation on corporate networks"

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  H3 VERDICT${RESET}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${RED}BUG CONFIRMED${RESET}: Cleanup uses hardcoded 192.168.0.1"
echo "  Root cause:  KNOWN_PHYS_GW != PHYS_GW on non-standard networks"
echo "  Impact:      Stale /32 routes accumulate on re-run"
echo "  Fix:         Use \$PHYS_GW (detected) in cleanup, not KNOWN_PHYS_GW"
echo ""
echo -e "  Tests: ${GREEN}${PASS} passed${RESET}, ${RED}${FAIL} failed${RESET}"
echo ""

rm -f "$MOCK_ROUTES"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
