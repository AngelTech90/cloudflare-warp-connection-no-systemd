#!/usr/bin/env bash
# =============================================================================
# wgcf-run.sh  —  DAILY TUNNEL CONTROL
#
# Manages the Cloudflare WARP WireGuard tunnel after setup.
# Run warp-wgcf-setup.sh first if the tunnel is not yet configured.
#
# USAGE:
#   sudo ./wgcf-run.sh <command>
#
# COMMANDS:
#   start    — bring the tunnel up
#   stop     — bring the tunnel down
#   restart  — stop then start
#   status   — show interface state, handshake, and traffic stats
#   test     — verify warp=on, show active routes, confirm proxy tables intact
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
die()     { echo -e "${RED}[error]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}▶ $*${RESET}"; }

# ── config ────────────────────────────────────────────────────────────────────
WARP_IFACE="warp"
WARP_CONF="/etc/wireguard/warp.conf"

# Known topology values — used for route verification in test command
KNOWN_PHYS_IFACE="eth0"
KNOWN_PHYS_GW="192.168.0.1"
KNOWN_VPN_SUBNET="10.96.0.0/16"
KNOWN_PHYS_LAN="192.168.0.0/24"

# ── DNS save/restore ──────────────────────────────────────────────────────────
DNS_BACKUP="/run/warp-dns-backup.resolv.conf"

save_dns_state() {
    if [[ -f /etc/resolv.conf ]]; then
        mkdir -p "$(dirname "$DNS_BACKUP")"
        cp /etc/resolv.conf "$DNS_BACKUP"
        info "DNS state saved: $(grep nameserver "$DNS_BACKUP" 2>/dev/null | tr '\n' ' ')"
    else
        warn "/etc/resolv.conf not found — skipping DNS backup."
    fi
}

restore_dns_state() {
    if [[ -f "$DNS_BACKUP" ]]; then
        cp "$DNS_BACKUP" /etc/resolv.conf
        info "DNS state restored: $(grep nameserver /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
        rm -f "$DNS_BACKUP"
    else
        warn "No DNS backup found at $DNS_BACKUP — /etc/resolv.conf not restored."
        # Last-resort fallback: Cloudflare DNS
        if [[ ! -f /etc/resolv.conf ]] || ! grep -q nameserver /etc/resolv.conf; then
            echo "nameserver 1.1.1.1" > /etc/resolv.conf
            info "Fallback: set DNS to 1.1.1.1"
        fi
    fi
}

# ── kill switch ───────────────────────────────────────────────────────────────
# WARP handshake endpoint: 162.159.192.0/24, UDP port 2408
# Excludes LAN (192.168.0.0/24) and WARP handshake from the block.
enable_kill_switch() {
    info "Enabling kill switch (block non-WARP egress on physical interface)..."
    iptables -C OUTPUT -o lo -j ACCEPT 2>/dev/null || iptables -A OUTPUT -o lo -j ACCEPT
    iptables -C OUTPUT -o "$PHYS_IFACE" -p udp --dport 2408 -d 162.159.192.0/24 -j ACCEPT 2>/dev/null \
        || iptables -A OUTPUT -o "$PHYS_IFACE" -p udp --dport 2408 -d 162.159.192.0/24 -j ACCEPT
    iptables -C OUTPUT -o "$PHYS_IFACE" -d "$KNOWN_PHYS_LAN" -j ACCEPT 2>/dev/null \
        || iptables -A OUTPUT -o "$PHYS_IFACE" -d "$KNOWN_PHYS_LAN" -j ACCEPT
    iptables -C OUTPUT -o "$WARP_IFACE" -j ACCEPT 2>/dev/null \
        || iptables -A OUTPUT -o "$WARP_IFACE" -j ACCEPT
    iptables -C OUTPUT -o "$PHYS_IFACE" -j DROP 2>/dev/null \
        || iptables -A OUTPUT -o "$PHYS_IFACE" -j DROP
    success "Kill switch active — egress blocked on $PHYS_IFACE except WARP + LAN"
}

disable_kill_switch() {
    info "Disabling kill switch..."
    iptables -D OUTPUT -o "$PHYS_IFACE" -j DROP 2>/dev/null || true
    iptables -D OUTPUT -o "$WARP_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o "$PHYS_IFACE" -d "$KNOWN_PHYS_LAN" -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o "$PHYS_IFACE" -p udp --dport 2408 -d 162.159.192.0/24 -j ACCEPT 2>/dev/null || true
    success "Kill switch removed."
}

# ── guards ────────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0 $*"
}

require_config() {
    [[ -f "$WARP_CONF" ]] || \
        die "Config not found: ${WARP_CONF}\nRun setup first: sudo ./warp-wgcf-setup.sh"
}

detect_physical_iface() {
    PHYS_IFACE=$(ip route show default \
        | grep -v 'dev tun' \
        | grep -E 'dev (eth|enp|wlan|wlp|ens|eno|bond|wwan|br|enx)' \
        | head -1 \
        | awk '{print $5}')
    [[ -z "$PHYS_IFACE" ]] && PHYS_IFACE="$KNOWN_PHYS_IFACE"
}

# ── commands ──────────────────────────────────────────────────────────────────
cmd_start() {
    section "Starting WARP tunnel"

    if ip link show "$WARP_IFACE" &>/dev/null; then
        warn "Interface '$WARP_IFACE' already exists."
        info "Current state:"
        wg show "$WARP_IFACE" 2>/dev/null || true
        info "Use 'restart' to cycle it."
        exit 0
    fi

    save_dns_state
    detect_physical_iface

    # if/else prevents set -e from killing the script before error handling
    if ! wg-quick up "$WARP_IFACE"; then
        die "wg-quick up failed.\nCheck: dmesg | tail -20"
    fi
    sleep 2

    if ip link show "$WARP_IFACE" &>/dev/null; then
        success "Tunnel is up"
        ip addr show "$WARP_IFACE" | grep 'inet ' | while IFS= read -r l; do info "  $l"; done || true
        enable_kill_switch
    else
        warn "Interface $WARP_IFACE did not appear after wg-quick up.\nCheck: dmesg | tail -20"
    fi
}

cmd_stop() {
    section "Stopping WARP tunnel"

    if ! ip link show "$WARP_IFACE" &>/dev/null; then
        warn "Interface '$WARP_IFACE' is not up — nothing to stop."
        exit 0
    fi

    detect_physical_iface
    disable_kill_switch

    # || true ensures restore_dns_state ALWAYS runs — even if wg-quick down fails.
    # Without this, a failed wg-quick down would leave DNS pointed at 1.1.1.1 forever.
    wg-quick down "$WARP_IFACE" || true
    sleep 1

    if ip link show "$WARP_IFACE" &>/dev/null; then
        warn "Interface still present after wg-quick down — forcing removal."
        ip link delete "$WARP_IFACE" 2>/dev/null || true
    fi

    restore_dns_state
    success "Tunnel stopped"
}

cmd_restart() {
    section "Restarting WARP tunnel"
    cmd_stop
    sleep 1
    cmd_start
}

cmd_status() {
    section "WARP tunnel status"

    # Interface state
    if ip link show "$WARP_IFACE" &>/dev/null; then
        success "Interface '$WARP_IFACE' is UP"
        echo ""
        ip addr show "$WARP_IFACE" | grep -E '(inet|link)' | while IFS= read -r l; do
            info "  $l"
        done
    else
        warn "Interface '$WARP_IFACE' is DOWN"
        info "Start with: sudo ./wgcf-run.sh start"
        exit 1
    fi

    # WireGuard peer details
    echo ""
    info "WireGuard peer info:"
    wg show "$WARP_IFACE" 2>/dev/null | while IFS= read -r l; do
        info "  $l"
    done

    # Check handshake age — warn if stale
    local handshake_line
    handshake_line=$(wg show "$WARP_IFACE" 2>/dev/null | grep "latest handshake" || true)
    if [[ -z "$handshake_line" ]]; then
        warn "No handshake yet — tunnel may not have connected."
        info "Try restarting: sudo ./wgcf-run.sh restart"
    else
        info "  $handshake_line"
    fi

    # Active routes for this interface
    echo ""
    info "Routes via $WARP_IFACE:"
    ip route show dev "$WARP_IFACE" 2>/dev/null | while IFS= read -r l; do
        info "  $l"
    done
}

cmd_test() {
    section "Testing WARP tunnel end-to-end"

    # 1. Interface must be up
    if ! ip link show "$WARP_IFACE" &>/dev/null; then
        die "Interface '$WARP_IFACE' is not up.\nStart it first: sudo ./wgcf-run.sh start"
    fi
    success "Interface '$WARP_IFACE' is up"

    # 2. WireGuard handshake check
    echo ""
    info "WireGuard handshake:"
    wg show "$WARP_IFACE" 2>/dev/null \
        | grep -E '(endpoint|latest handshake|transfer)' \
        | while IFS= read -r l; do info "  $l"; done

    # 3. Cloudflare trace — the definitive test
    echo ""
    info "Cloudflare trace (checking warp= field):"
    local trace
    trace=$(curl -s --max-time 15 https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)

    if [[ -z "$trace" ]]; then
        warn "Could not reach cloudflare.com — check connectivity."
    elif echo "$trace" | grep -q "warp=on"; then
        success "warp=on — traffic is routing through Cloudflare WARP"
        echo "$trace" | grep -E "^(ip|warp|loc|colo)=" | while IFS= read -r l; do
            info "  $l"
        done
    elif echo "$trace" | grep -q "warp=plus"; then
        success "warp=plus — WARP+ active"
        echo "$trace" | grep -E "^(ip|warp|loc|colo)=" | while IFS= read -r l; do
            info "  $l"
        done
    else
        warn "warp=off — connected to Cloudflare but traffic not tunnelling."
        echo "$trace" | grep -E "^(ip|warp|loc|colo)=" | while IFS= read -r l; do
            info "  $l"
        done
        info "Try: sudo ./wgcf-run.sh restart"
    fi

    # 4. Route table — confirm WARP /1 routes are present
    echo ""
    info "WARP routes in main table (expect two /1 entries):"
    ip route show dev "$WARP_IFACE" 2>/dev/null | while IFS= read -r l; do
        info "  $l"
    done

    # 5. Confirm exclusion routes are in place
    echo ""
    info "Exclusion routes (VPN subnet + LAN should bypass WARP):"
    for subnet in "$KNOWN_VPN_SUBNET" "$KNOWN_PHYS_LAN"; do
        local r
        r=$(ip route show "$subnet" 2>/dev/null | head -1 || true)
        if [[ -n "$r" ]]; then
            info "  $r"
        else
            warn "  $subnet — exclusion route NOT found (should be via ${KNOWN_PHYS_GW} dev ${KNOWN_PHYS_IFACE})"
        fi
    done

    # 6. Proxy policy tables — confirm they are intact
    echo ""
    info "Proxy policy tables (should all still show default via tun*):"
    for table in usa netherlands switzerland mexico japan canada 106 107 108 109 110 111; do
        local entry
        entry=$(ip route show table "$table" 2>/dev/null | grep default | head -1 || true)
        if [[ -n "$entry" ]]; then
            info "  table ${table}: $entry"
        else
            warn "  table ${table}: NOT FOUND — proxy route may be down"
        fi
    done

    # 7. Physical default route — the /0 entry must still exist
    echo ""
    info "Physical default route (must still exist in main table):"
    local phys_default
    phys_default=$(ip route show default dev "$KNOWN_PHYS_IFACE" 2>/dev/null | head -1 || true)
    if [[ -n "$phys_default" ]]; then
        info "  $phys_default"
    else
        warn "  Physical default route on ${KNOWN_PHYS_IFACE} not found — check your routing table."
    fi
}

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo -e "${BOLD}wgcf-run.sh${RESET} — Cloudflare WARP tunnel control"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET} sudo ./wgcf-run.sh <command>"
    echo ""
    echo -e "  ${CYAN}start${RESET}    bring the tunnel up"
    echo -e "  ${CYAN}stop${RESET}     bring the tunnel down"
    echo -e "  ${CYAN}restart${RESET}  stop then start"
    echo -e "  ${CYAN}status${RESET}   interface state, handshake, traffic stats"
    echo -e "  ${CYAN}test${RESET}     verify warp=on, routes, proxy tables"
    echo ""
    echo -e "  Setup:   sudo ./warp-wgcf-setup.sh"
    echo -e "  Remove:  sudo ./warp-wgcf-setup.sh --uninstall"
    echo ""
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"

    case "$cmd" in
        start)   require_root; require_config; cmd_start   ;;
        stop)    require_root; require_config; cmd_stop    ;;
        restart) require_root; require_config; cmd_restart ;;
        status)  require_root; require_config; cmd_status  ;;
        test)    require_root; require_config; cmd_test    ;;
        *)       usage; exit 0 ;;
    esac
}

main "$@"
