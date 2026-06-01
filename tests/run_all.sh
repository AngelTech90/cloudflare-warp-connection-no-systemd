#!/usr/bin/env bash
# =============================================================================
# RUN ALL TESTS
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║     CLOUDFLARE WARP — BUG VERIFICATION TEST SUITE        ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0
declare -A RESULTS

run_test() {
    local test_name="$1"
    local test_file="$TESTS_DIR/$test_name"

    echo -e "${BOLD}${CYAN}━━━ Running: $test_name ━━━${RESET}"
    echo ""

    if [[ ! -f "$test_file" ]]; then
        echo -e "  ${RED}SKIP: test file not found${RESET}"
        RESULTS["$test_name"]="SKIP"
        return
    fi

    if [[ ! -x "$test_file" ]]; then
        chmod +x "$test_file"
    fi

    if bash "$test_file" 2>&1; then
        RESULTS["$test_name"]="PASS"
        TOTAL_PASS=$((TOTAL_PASS + 1))
        echo ""
        echo -e "  ${GREEN}${BOLD}TEST PASSED: $test_name${RESET}"
    else
        RESULTS["$test_name"]="FAIL"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        echo ""
        echo -e "  ${RED}${BOLD}TEST FAILED: $test_name${RESET}"
    fi

    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────${RESET}"
    echo ""
}

echo -e "${YELLOW}Note: Some tests are probabilistic (TOCTOU races).${RESET}"
echo -e "${YELLOW}One success proves the bug. Repeated failures suggest bug doesn't exist.${RESET}"
echo ""

# Run tests in dependency order
run_test "test_c1_daemon_sourcing_bug.sh"
run_test "test_h2_route_error_suppression.sh"
run_test "test_h3_hardcoded_cleanup.sh"
run_test "test_m1_permission_race.sh"
run_test "test_m4_pid_race.sh"
run_test "test_prd_scoping.sh"

# ── Final Report ──────────────────────────────────────────────────────────

echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║                   FINAL TEST REPORT                      ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

for test_name in test_c1_daemon_sourcing_bug.sh test_h2_route_error_suppression.sh test_h3_hardcoded_cleanup.sh test_m1_permission_race.sh test_m4_pid_race.sh test_prd_scoping.sh; do
    result="${RESULTS[$test_name]:-NOT RUN}"
    case "$result" in
        PASS) echo -e "  ${GREEN}✓${RESET} $test_name" ;;
        FAIL) echo -e "  ${RED}✗${RESET} $test_name" ;;
        SKIP) echo -e "  ${YELLOW}−${RESET} $test_name (skipped)" ;;
        *)    echo -e "  ${YELLOW}?${RESET} $test_name (unknown)" ;;
    esac
done

echo ""
echo -e "  ${GREEN}Passed: $TOTAL_PASS${RESET}"
echo -e "  ${RED}Failed: $TOTAL_FAIL${RESET}"
echo ""

if [[ $TOTAL_FAIL -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}SOME BUGS NOT CONFIRMED — review failed tests${RESET}"
    exit 1
else
    echo -e "  ${GREEN}${BOLD}ALL BUGS CONFIRMED — fixing is justified${RESET}"
    exit 0
fi
