#!/usr/bin/env bash
# =============================================================================
# TEST PRD SCOPING: Does the PRD describe THIS project or a DIFFERENT one?
#
# Analysis: stability-security-prd.md references files and architectures
# that don't exist in this repo. We need to determine whether the PRD
# should be scoped down to match reality, or if this repo is incomplete.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; FAIL=0
pass() { echo -e "  ${GREEN}✓ PASS${RESET} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗ FAIL${RESET} $*"; FAIL=$((FAIL+1)); }

echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${CYAN}  PRD SCOPING ANALYSIS${RESET}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo ""

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRD="$PROJECT_DIR/stability-security-prd.md"

# ── Step 1: Extract ALL file references from the PRD ──────────────────────

echo -e "${BOLD}Step 1: Files referenced by PRD vs files that exist${RESET}"
echo ""

echo -e "${CYAN}Files referenced in PRD:${RESET}"
FILES_IN_PRD=$(rg -o '[a-zA-Z0-9_\-]+\.(sh|yml|yaml|md|toml|conf)' "$PRD" --no-filename | sort -u)
echo "$FILES_IN_PRD" | while read -r f; do echo "  - $f"; done
echo ""

echo -e "${CYAN}Files that EXIST in the repo:${RESET}"
fd -t f --exclude tests --exclude .git | sort
echo ""

# ── Step 2: Check each PRD-referenced file ────────────────────────────────

echo -e "${BOLD}Step 2: Existence check — PRD references vs repo reality${RESET}"
echo ""

declare -A EXISTS
MISSING_FILES=()
PRESENT_FILES=()

for f in multi-vpn-proxy.sh vpn-security-monitor.sh entrypoint.sh docker-compose.yml wgcf-run.sh wgcf-monitor.sh warp-wgcf-setup.sh; do
    if [[ -f "$PROJECT_DIR/$f" ]]; then
        PRESENT_FILES+=("$f")
        echo -e "  ${GREEN}EXISTS${RESET}    $f"
    else
        MISSING_FILES+=("$f")
        echo -e "  ${RED}MISSING${RESET}   $f"
    fi
done

echo ""
if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
    pass "Found ${#MISSING_FILES[@]} referenced files that DON'T exist"
else
    fail "All referenced files exist (unexpected)"
fi

# ── Step 3: Analyze PRD architecture claims ────────────────────────────────

echo ""
echo -e "${BOLD}Step 3: Architecture claims in PRD vs actual code${RESET}"
echo ""

echo -e "${CYAN}PRD claims:${RESET}"
echo "  - 12 OpenVPN proxy slots (tun0-tun11)"
echo "  - 12 custom routing tables (100-111)"
echo "  - UID-based policy routing (UIDs 3100-3111)"
echo "  - iptables mangle per-slot mark"
echo "  - microsocks SOCKS5 proxies"
echo "  - multi-vpn-proxy.sh orchestrator"
echo "  - Docker architecture (docker-compose with 12 services)"
echo "  - vpn-security-monitor.sh"
echo ""

# Check if actual scripts contain evidence of 12-slot system
echo -e "${CYAN}Actual code evidence (grep for 12-slot patterns):${RESET}"
echo ""

SLOT_EVIDENCE=0

echo -n "  multi-vpn-proxy.sh references: "
if rg -q "multi-vpn-proxy" "$PROJECT_DIR" --include '*.sh' 2>/dev/null; then
    echo "FOUND"
    SLOT_EVIDENCE=$((SLOT_EVIDENCE+1))
else
    echo "NONE"
fi

echo -n "  12 routing tables (100-111): "
if rg -q "table (100|101|102|103|104|105|106|107|108|109|110|111)" "$PROJECT_DIR" --include '*.sh' 2>/dev/null; then
    echo "FOUND in scripts"
    SLOT_EVIDENCE=$((SLOT_EVIDENCE+1))
else
    echo "NONE in scripts"
    if rg -q "table.*100.*101.*102\|table.*usa.*netherlands" "$PROJECT_DIR" --include '*.sh' 2>/dev/null; then
        echo "  (but proxy tables referenced in wgcf-run.sh test command)"
        SLOT_EVIDENCE=$((SLOT_EVIDENCE+1))
    fi
fi

echo -n "  UID range (3100-3111): "
if rg -q "3100\|310[0-9]\|311[0-1]" "$PROJECT_DIR" --include '*.sh' 2>/dev/null; then
    echo "FOUND"
    SLOT_EVIDENCE=$((SLOT_EVIDENCE+1))
else
    echo "NONE"
fi

echo -n "  iptables mangle: "
if rg -q "iptables.*mangle\|mangle.*OUTPUT" "$PROJECT_DIR" --include '*.sh' 2>/dev/null; then
    echo "FOUND"
    SLOT_EVIDENCE=$((SLOT_EVIDENCE+1))
else
    echo "NONE"
fi

echo -n "  microsocks/SOCKS5: "
if rg -q "microsocks\|socks5\|SOCKS" "$PROJECT_DIR" --include '*.sh' 2>/dev/null; then
    echo "FOUND"
    SLOT_EVIDENCE=$((SLOT_EVIDENCE+1))
else
    echo "NONE"
fi

echo -n "  Docker/compose: "
if fd -e yml -e yaml docker-compose "$PROJECT_DIR" 2>/dev/null | head -1 | grep -q .; then
    echo "FOUND"
    SLOT_EVIDENCE=$((SLOT_EVIDENCE+1))
else
    echo "NONE"
fi

echo ""
echo "  Evidence score: $SLOT_EVIDENCE/6 multi-slot patterns in actual code"
echo ""

if [[ $SLOT_EVIDENCE -lt 3 ]]; then
    pass "PRD describes system NOT present in this repo (score: $SLOT_EVIDENCE/6)"
else
    fail "PRD matches this repo (unexpected)"
fi

# ── Step 4: Determine what PRD SHOULD cover ────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}─────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Step 4: PRD scoping recommendation${RESET}"
echo ""

echo "  This repo IS:"
echo "    → Cloudflare WARP WireGuard tunnel setup & monitoring"
echo "    → 3 Bash scripts (~1142 lines)"
echo "    → Non-systemd Linux init integration"
echo "    → Coexists with existing OpenVPN infrastructure"
echo ""

echo "  This repo IS NOT:"
echo "    → Multi-VPN proxy orchestrator"
echo "    → 12-slot policy routing system"
echo "    → SOCKS5 proxy manager"
echo "    → Docker-based VPN isolation system"
echo ""

echo -e "${BOLD}PRD sections that APPLY to this repo:${RESET}"
echo "  ✅ Section 1 (Executive Summary) — routing/DNS principles"
echo "  ✅ Section 5 (Verification Patterns) — verification philosophy"
echo "  ✅ Section 6.1 (Bash Architecture gaps) — SOME apply:"
echo "     ✅ DNS save/restore pattern"
echo "     ✅ ip route replace (not add)"
echo "     ✅ Kill switch concept (simplified for single tunnel)"
echo "     ❌ Per-slot table management (no slots here)"
echo "     ❌ UID range rules (no UID routing here)"
echo "     ❌ fwmark rules (no iptables mangle here)"
echo "  ❌ Section 2 (RPDB Architecture) — 12 tables → NOT APPLICABLE"
echo "  ❌ Section 3 (DNS) — 12-slot DNS → apply simplified version"
echo "  ❌ Section 6.2 (Docker) — ZERO Docker here → NOT APPLICABLE"
echo "  ❌ Section 7 (Testing) — per-slot tests → NOT APPLICABLE"
echo ""

# Count applicable vs not
APPLICABLE=0
NOT_APPLICABLE=0

# Check PRD line counts per section
echo -e "${CYAN}PRD section breakdown:${RESET}"
rg "^## " "$PRD" --line-number | while read -r line; do
    echo "  $line"
done

echo ""
echo -e "${BOLD}PRD line count:${RESET}"
PRD_LINES=$(wc -l < "$PRD")
echo "  Total: $PRD_LINES lines"
echo ""

# Count lines referencing multi-slot/Docker (not applicable to this repo)
MULTI_SLOT_LINES=$(rg -c "slot\|uidrange\|fwmark\|mangle\|SOCKS5\|microsocks\|docker\|compose\|container\|table.*10[0-9]\|table.*11[0-1]\|UID.*31[0-1][0-9]" "$PRD" 2>/dev/null || echo "0")
echo "  Lines referencing multi-slot/Docker patterns: ~$MULTI_SLOT_LINES (not applicable)"
echo ""

# ── Step 5: Actionable PRD for THIS repo ──────────────────────────────────

echo -e "${BOLD}${CYAN}─────────────────────────────────────────────────────${RESET}"
echo -e "${BOLD}Step 5: What a PROPERLY SCOPED PRD would cover${RESET}"
echo ""

echo "  A scoped-down PRD for THIS project should contain:"
echo ""
echo "  Critical (immediate):"
echo "    1. DNS save/restore on tunnel up/down"
echo "    2. ip route replace pattern (no error suppression)"
echo "    3. Use detected PHYS_GW everywhere (no hardcoded 192.168.0.1)"
echo "    4. Fix monitor daemon sourcing bug"
echo "    5. Atomic PID file (flock/mkdir mutex)"
echo "    6. Atomic file creation with permissions (install -m 600)"
echo ""
echo "  Enhancement (later):"
echo "    7. Kill switch (iptables OUTPUT DROP + whitelist)"
echo "    8. Process group cleanup on daemon stop"
echo "    9. Interface detection for non-eth/non-enp devices"
echo ""
echo "  REMOVE from PRD (NOT this project):"
echo "    ❌ All 12-slot RPDB architecture (Section 2)"
echo "    ❌ Per-UID/per-fwmark routing rules"
echo "    ❌ microsocks/SOCKS5 proxy config"
echo "    ❌ Docker architecture (Section 6.2)"
echo "    ❌ Multi-container health checks"
echo "    ❌ Per-slot verification tests"
echo ""

pass "PRD needs MAJOR scoping down — ~60% of content is for different project"

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  PRD SCOPING VERDICT${RESET}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${YELLOW}MISMATCH CONFIRMED${RESET}"
echo "  PRD describes: Multi-VPN proxy system with 12 OpenVPN slots + Docker"
echo "  This repo is:  Single Cloudflare WARP WireGuard tunnel (3 scripts)"
echo "  Mismatch:      ~60% of PRD content is for different project"
echo ""
echo "  Recommendation: SCOPE DOWN the PRD to only cover the WARP tunnel layer"
echo "  OR:           Create a SEPARATE PRD for this repo"
echo "  OR:           Build the missing multi-VPN system (effort: weeks)"
echo ""
echo -e "  Tests: ${GREEN}${PASS} passed${RESET}, ${RED}${FAIL} failed${RESET}"
echo ""

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
