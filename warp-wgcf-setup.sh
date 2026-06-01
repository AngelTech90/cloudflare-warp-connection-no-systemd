#!/usr/bin/env bash
# =============================================================================
# warp-wgcf-setup.sh  —  ONE-TIME SETUP
#
# Installs Cloudflare WARP via wgcf + wg-quick on non-systemd Debian-based
# distros (Devuan, LOC-OS 24, antiX, MX Linux, etc.)
#
# Topology:
#   tun0-tun11  → per-country OpenVPN proxies (policy routing tables)
#   eth0        → default unprotected path  ← WARP covers this
#
# Safe to re-run — cleans up previous state before starting fresh.
# Does NOT manage daily tunnel state — use wgcf-run.sh for that.
#
# USAGE:
#   chmod +x warp-wgcf-setup.sh
#   sudo ./warp-wgcf-setup.sh
#
#   WARP+ upgrade:
#   WARP_LICENSE_KEY=your-key sudo ./warp-wgcf-setup.sh
#
#   Full uninstall:
#   sudo ./warp-wgcf-setup.sh --uninstall
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
die()     { echo -e "${RED}[error]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}▶ $*${RESET}"; }

# ── paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WGCF_FINAL_DIR="/etc/wireguard/wgcf"
WARP_CONF="/etc/wireguard/warp.conf"
WGCF_BIN="/usr/local/bin/wgcf"
WARP_IFACE="warp"
WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"

# ── known topology (confirmed from ip route show table all) ───────────────────
KNOWN_PHYS_IFACE="eth0"
KNOWN_PHYS_GW="192.168.0.1"
KNOWN_PHYS_LAN="192.168.0.0/24"
KNOWN_VPN_SUBNET="10.96.0.0/16"

PHYS_IFACE=""
PHYS_GW=""
INIT_SYSTEM=""

# ── helpers ───────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"
    info "Script directory: ${BOLD}${SCRIPT_DIR}${RESET}"
    info "wgcf writes files here first, then moves them to /etc/wireguard/wgcf/"
}

detect_init() {
    if   command -v rc-update   &>/dev/null; then INIT_SYSTEM="openrc"
    elif command -v sv          &>/dev/null && [[ -d /var/service ]]; then INIT_SYSTEM="runit"
    elif command -v update-rc.d &>/dev/null; then INIT_SYSTEM="sysvinit"
    else INIT_SYSTEM="unknown"
    fi
    info "Init system: ${BOLD}${INIT_SYSTEM}${RESET}"
}

detect_physical_route() {
    step "Detecting unprotected physical default route"

    local route_line
    route_line=$(ip route show default \
        | grep -v 'dev tun' \
        | grep -E 'dev (eth|enp|wlan|wlp|ens|eno)' \
        | head -1)

    [[ -z "$route_line" ]] && \
        die "No physical default route found.\nRun: ip route show default | grep -v 'dev tun'"

    PHYS_GW=$(   echo "$route_line" | awk '{print $3}')
    PHYS_IFACE=$(echo "$route_line" | awk '{print $5}')

    [[ "$PHYS_IFACE" != "$KNOWN_PHYS_IFACE" ]] && \
        warn "Detected '${PHYS_IFACE}' differs from expected '${KNOWN_PHYS_IFACE}' — using detected."
    [[ "$PHYS_GW" != "$KNOWN_PHYS_GW" ]] && \
        warn "Detected gateway '${PHYS_GW}' differs from expected '${KNOWN_PHYS_GW}' — using detected."

    success "Physical interface : ${BOLD}${PHYS_IFACE}${RESET}"
    success "Physical gateway   : ${BOLD}${PHYS_GW}${RESET}"
    info    "tun0–tun11 proxy tables will not be touched."
}

# ── cleanup ───────────────────────────────────────────────────────────────────
# Removes all WARP state — tunnel interface, stale routes, config files,
# boot service. Called at the start of setup to ensure a clean slate.
# Also callable directly via --uninstall.
cleanup() {
    step "Cleaning up WARP state"

    # Bring tunnel down if it is running
    if ip link show "$WARP_IFACE" &>/dev/null; then
        info "Tunnel '$WARP_IFACE' is up — bringing it down..."
        wg-quick down "$WARP_IFACE" 2>/dev/null || true
        sleep 1
        ip link delete "$WARP_IFACE" 2>/dev/null || true
        success "Tunnel brought down"
    else
        info "No active tunnel — nothing to bring down."
    fi

    # Remove stale /32 host routes for Cloudflare endpoint (from previous PreUp)
    # Uses PHYS_GW (detected gateway) instead of hardcoded KNOWN_PHYS_GW
    # to work correctly on networks with non-192.168.0.x gateways.
    ip route show | grep "/32.*via.*${PHYS_GW}" | awk '{print $1}' \
        | while read -r r; do
            info "Removing stale host route: $r"
            ip route del "$r" 2>/dev/null || true
        done

    # Remove stale PostUp exclusion routes (VPN subnet + LAN)
    for subnet in "$KNOWN_VPN_SUBNET" "$KNOWN_PHYS_LAN"; do
        if ip route show | grep -q "^${subnet}.*via.*${PHYS_GW}"; then
            info "Removing stale exclusion route: $subnet"
            ip route del "$subnet" via "$PHYS_GW" 2>/dev/null || true
        fi
    done

    # Remove config files
    [[ -f "$WARP_CONF" ]] && { info "Removing $WARP_CONF"; rm -f "$WARP_CONF"; }
    [[ -f "${WGCF_FINAL_DIR}/wgcf-profile.conf" ]] && {
        info "Removing wgcf-profile.conf (will regenerate)"
        rm -f "${WGCF_FINAL_DIR}/wgcf-profile.conf"
    }
    # NOTE: wgcf-account.toml is intentionally kept — avoids re-registering
    # a new device on every setup run. Delete manually only if you want a
    # completely fresh device identity.

    # Remove leftover files from a previous failed run in SCRIPT_DIR
    rm -f "${SCRIPT_DIR}/wgcf-profile.conf"
    # Do NOT remove account.toml from SCRIPT_DIR either — same reason above

    # Remove boot service
    case "$INIT_SYSTEM" in
        openrc)
            rc-service warp-wgcf stop 2>/dev/null || true
            rc-update del warp-wgcf 2>/dev/null || true
            rm -f /etc/init.d/warp-wgcf
            ;;
        runit)
            rm -f /var/service/warp-wgcf
            rm -rf /etc/sv/warp-wgcf
            ;;
        sysvinit)
            update-rc.d warp-wgcf remove 2>/dev/null || true
            rm -f /etc/init.d/warp-wgcf
            ;;
    esac

    success "Cleanup complete."
}

# Called by --uninstall: cleanup + remove wgcf binary + account + wgcf dir
full_uninstall() {
    detect_init
    cleanup

    info "Removing wgcf binary..."
    rm -f "$WGCF_BIN"

    info "Removing WARP device credentials..."
    rm -rf "$WGCF_FINAL_DIR"

    success "Full uninstall complete."
    info "To reinstall: sudo ./warp-wgcf-setup.sh"
    exit 0
}

# ── step 1: dependencies ─────────────────────────────────────────────────────
install_deps() {
    step "Installing dependencies"
    apt-get update -qq

    # wireguard-tools: provides wg and wg-quick
    if ! command -v wg &>/dev/null; then
        info "Installing wireguard-tools..."
        apt-get install -y wireguard-tools
        success "wireguard-tools installed"
    else
        success "wireguard-tools already present ($(wg --version 2>/dev/null | head -1))"
    fi

    # openresolv: provides resolvconf for wg-quick DNS= handling on non-systemd.
    # Without this, wg-quick fails with "resolvconf: command not found" and
    # tears down the interface immediately after creating it.
    if ! command -v resolvconf &>/dev/null; then
        info "Installing openresolv..."
        apt-get install -y openresolv
        success "openresolv installed"
    else
        success "resolvconf already available"
    fi

    command -v curl &>/dev/null || apt-get install -y curl
    command -v dig  &>/dev/null || apt-get install -y dnsutils
}

# ── step 2: install wgcf ─────────────────────────────────────────────────────
install_wgcf() {
    step "Installing wgcf"

    # Validate existing binary actually executes.
    # wgcf has no --version flag — run with no args, check output has "register"
    if command -v wgcf &>/dev/null; then
        local help_out
        help_out=$(wgcf 2>&1 || true)
        if echo "$help_out" | grep -q "register"; then
            success "wgcf already installed and working ($(which wgcf))"
            return
        else
            warn "wgcf at $(which wgcf) does not run correctly — reinstalling."
            rm -f "$(which wgcf)"
        fi
    fi

    local arch; arch=$(uname -m)
    local asset
    case "$arch" in
        x86_64)  asset="linux_amd64" ;;
        aarch64) asset="linux_arm64" ;;
        armv7l)  asset="linux_arm"   ;;
        i686)    asset="linux_386"   ;;
        *)       die "Unsupported architecture: $arch" ;;
    esac

    # Try GitHub API first, fall back to known-good version
    local FALLBACK_VERSION="2.2.30"
    local FALLBACK_URL="https://github.com/ViRb3/wgcf/releases/download/v${FALLBACK_VERSION}/wgcf_${FALLBACK_VERSION}_${asset}"
    local url=""

    info "Fetching latest wgcf release URL..."
    url=$(curl -fsSL --max-time 10 \
        https://api.github.com/repos/ViRb3/wgcf/releases/latest \
        2>/dev/null \
        | grep "browser_download_url" \
        | grep "\"wgcf_.*_${asset}\"" \
        | cut -d'"' -f4 \
        | head -1 || true)

    if [[ -z "$url" ]]; then
        warn "GitHub API unavailable — falling back to v${FALLBACK_VERSION}"
        url="$FALLBACK_URL"
    else
        info "Latest release: $url"
    fi

    local tmp_bin="/tmp/wgcf-download-$$"
    info "Downloading wgcf..."
    curl -fsSL --max-time 60 "$url" -o "$tmp_bin"

    # Validate ELF magic bytes — catches 404 HTML and empty downloads
    [[ ! -s "$tmp_bin" ]] && { rm -f "$tmp_bin"; die "Downloaded file is empty.\nURL: ${url}"; }
    local magic
    magic=$(head -c 4 "$tmp_bin" | xxd -p 2>/dev/null || true)
    if [[ "$magic" != "7f454c46" ]]; then
        rm -f "$tmp_bin"
        die "Not a valid ELF binary (magic: ${magic}).\nURL: ${url}\nCheck https://github.com/ViRb3/wgcf/releases"
    fi

    chmod +x "$tmp_bin"
    mv "$tmp_bin" "$WGCF_BIN"

    # Smoke test
    local smoke
    smoke=$(wgcf 2>&1 || true)
    if ! echo "$smoke" | grep -q "register"; then
        die "wgcf installed but does not run.\nOutput: $smoke"
    fi
    success "wgcf installed and working → $WGCF_BIN"
}

# ── step 3: register and generate — local first, then move ───────────────────
generate_config() {
    step "Registering WARP device and generating WireGuard profile"
    info "No credentials required — Cloudflare issues a device identity automatically."

    local account_file="${SCRIPT_DIR}/wgcf-account.toml"
    local profile_file="${SCRIPT_DIR}/wgcf-profile.conf"

    # If account exists in final dir but not locally, copy it back.
    # wgcf always reads/writes relative to its cwd — we run it from SCRIPT_DIR.
    if [[ -f "${WGCF_FINAL_DIR}/wgcf-account.toml" && ! -f "$account_file" ]]; then
        info "Found existing account — copying to SCRIPT_DIR for wgcf to read."
        cp "${WGCF_FINAL_DIR}/wgcf-account.toml" "$account_file"
    fi

    # Register only if no account exists yet
    if [[ ! -f "$account_file" ]]; then
        info "Calling Cloudflare registration API from: ${SCRIPT_DIR}"
        ( cd "$SCRIPT_DIR" && wgcf register )
        [[ -f "$account_file" ]] || \
            die "wgcf register ran but wgcf-account.toml not found in ${SCRIPT_DIR}."
        success "Device registered → ${account_file}"
    else
        info "wgcf-account.toml already exists — skipping registration."
    fi

    # WARP+ license (correct flag per wgcf README)
    if [[ -n "$WARP_LICENSE_KEY" ]]; then
        info "Applying WARP+ license key..."
        ( cd "$SCRIPT_DIR" && wgcf update --license-key "$WARP_LICENSE_KEY" )
        success "WARP+ license applied"
    else
        info "No WARP+ key — using free tier."
    fi

    # Generate WireGuard profile
    info "Generating WireGuard profile from: ${SCRIPT_DIR}"
    ( cd "$SCRIPT_DIR" && wgcf generate )
    [[ -f "$profile_file" ]] || \
        die "wgcf generate ran but wgcf-profile.conf not found in ${SCRIPT_DIR}."
    success "Profile generated → ${profile_file}"

    info "Raw profile (keys redacted):"
    grep -v 'Key' "$profile_file" | while IFS= read -r l; do
        [[ -n "$l" ]] && info "  $l"
    done

    # Move to final destination
    step "Moving wgcf files to ${WGCF_FINAL_DIR}"
    mkdir -p "$WGCF_FINAL_DIR"
    # install -m 600 copies and sets permissions atomically — no race window
    # where the file exists with default umask permissions before chmod runs.
    install -m 600 "$account_file" "${WGCF_FINAL_DIR}/wgcf-account.toml"
    install -m 600 "$profile_file"  "${WGCF_FINAL_DIR}/wgcf-profile.conf"
    success "Files secured in ${WGCF_FINAL_DIR}"
}

# ── step 4: patch config for your topology ───────────────────────────────────
patch_config() {
    step "Patching WireGuard config for your routing topology"

    local profile="${WGCF_FINAL_DIR}/wgcf-profile.conf"
    [[ -f "$profile" ]] || die "Profile not found at ${profile}"

    # Resolve endpoint to IPv4 — tun interfaces have IPv6 link-locals which
    # can cause dig/getent to return IPv6 first. The PreUp route uses
    # "ip route add X/32" which only works with IPv4.
    local endpoint_host endpoint_port endpoint_ip
    endpoint_host=$(grep '^Endpoint' "$profile" \
        | awk -F'=' '{print $2}' | awk -F':' '{print $1}' | tr -d ' ')
    endpoint_port=$(grep '^Endpoint' "$profile" \
        | awk -F':' '{print $NF}' | tr -d ' ')

    # Try 1: dig with explicit A record request
    endpoint_ip=$(dig +short -t A "$endpoint_host" 2>/dev/null \
        | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
        | head -1 || true)

    # Try 2: getent with IPv4-only flag
    if [[ -z "$endpoint_ip" ]]; then
        endpoint_ip=$(getent ahostsv4 "$endpoint_host" 2>/dev/null \
            | awk '/STREAM/{print $1}' | head -1 || true)
    fi

    # Try 3: DNS-over-HTTPS via Cloudflare
    if [[ -z "$endpoint_ip" ]]; then
        endpoint_ip=$(curl -s --max-time 5 \
            "https://1.1.1.1/dns-query?name=${endpoint_host}&type=A" \
            -H "accept: application/dns-json" 2>/dev/null \
            | grep -o '"data":"[0-9.]*"' | head -1 | cut -d'"' -f4 || true)
    fi

    [[ -z "$endpoint_ip" ]] && die "Cannot resolve ${endpoint_host} to IPv4."
    if ! echo "$endpoint_ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        die "Resolved '${endpoint_ip}' is not IPv4.\nTry: dig +short -t A ${endpoint_host}"
    fi
    info "Cloudflare endpoint: ${endpoint_host} → ${endpoint_ip}:${endpoint_port}"

    # Extract keys and addresses.
    # Profile may have "Address = IPv4, IPv6" on one comma-separated line
    # OR two separate Address lines. We split on commas, strip the prefix,
    # then keep only the token without a colon (IPv4 never has colons).
    local private_key address_v4 public_key
    private_key=$(grep '^PrivateKey' "$profile" | awk '{print $3}')
    public_key=$(  grep '^PublicKey'  "$profile" | awk '{print $3}')
    address_v4=$(grep '^Address' "$profile" \
        | tr ',' '\n' \
        | tr -d ' ' \
        | sed 's/^Address=//' \
        | grep -v ':' \
        | grep -E '^[0-9]' \
        | head -1)

    [[ -z "$private_key" ]] && die "Could not extract PrivateKey from ${profile}"
    [[ -z "$address_v4"  ]] && die "Could not extract IPv4 Address from ${profile}"
    [[ -z "$public_key"  ]] && die "Could not extract PublicKey from ${profile}"

    info "Extracted — Address: ${address_v4}  Endpoint: ${endpoint_ip}:${endpoint_port}"

    cat > "$WARP_CONF" << EOF
# ============================================================
# Cloudflare WARP — wgcf / wg-quick
# Generated by warp-wgcf-setup.sh
#
# Physical interface : ${PHYS_IFACE}
# Physical gateway   : ${PHYS_GW}
# Cloudflare endpoint: ${endpoint_ip}:${endpoint_port}
# OpenVPN subnet     : ${KNOWN_VPN_SUBNET} (excluded from WARP)
# LAN subnet         : ${KNOWN_PHYS_LAN} (excluded from WARP)
# ============================================================

[Interface]
PrivateKey = ${private_key}
Address    = ${address_v4}
DNS        = 1.1.1.1, 1.0.0.1
MTU        = 1280

# Split-horizon fix: route Cloudflare's endpoint via physical gateway
# BEFORE the tunnel comes up — prevents handshake loop.
# ip route replace is idempotent; no error suppression needed — if this
# fails the tunnel MUST NOT come up (handshake would loop into itself).
PreUp    = ip route replace ${endpoint_ip}/32 via ${PHYS_GW} dev ${PHYS_IFACE}
PostDown = ip route del ${endpoint_ip}/32 via ${PHYS_GW} dev ${PHYS_IFACE} 2>/dev/null || true

# Exclusion routes: keep OpenVPN server traffic and LAN on eth0 directly.
# Applied after the /1 AllowedIPs routes are active — more specific, they win.
# Using replace for idempotency; errors suppressed (these are nice-to-have).
PostUp   = ip route replace ${KNOWN_VPN_SUBNET} via ${PHYS_GW} dev ${PHYS_IFACE} 2>/dev/null || true
PostDown = ip route del ${KNOWN_VPN_SUBNET} via ${PHYS_GW} dev ${PHYS_IFACE} 2>/dev/null || true

PostUp   = ip route replace ${KNOWN_PHYS_LAN} via ${PHYS_GW} dev ${PHYS_IFACE} 2>/dev/null || true
PostDown = ip route del ${KNOWN_PHYS_LAN} via ${PHYS_GW} dev ${PHYS_IFACE} 2>/dev/null || true

[Peer]
PublicKey           = ${public_key}
Endpoint            = ${endpoint_ip}:${endpoint_port}

# Two-halves trick: 0.0.0.0/1 + 128.0.0.0/1 covers all IPv4 without
# replacing the kernel's /0 default route entry your proxy manager uses.
# No ::/0 — eth0 has no routable IPv6, only link-local fe80:: on tun ifaces.
AllowedIPs          = 0.0.0.0/1, 128.0.0.0/1

PersistentKeepalive = 25
EOF

    chmod 600 "$WARP_CONF"
    success "Config written → $WARP_CONF"
}

# ── step 5: verify files ──────────────────────────────────────────────────────
verify_structure() {
    step "Verifying /etc/wireguard structure"
    local ok=true
    for f in \
        "${WGCF_FINAL_DIR}/wgcf-account.toml" \
        "${WGCF_FINAL_DIR}/wgcf-profile.conf" \
        "$WARP_CONF"
    do
        if [[ -f "$f" ]]; then
            success "  $f  ($(stat -c "%a" "$f"))"
        else
            warn "  MISSING: $f"
            ok=false
        fi
    done
    $ok || die "Files missing — check errors above."
    info "Expected tree:"
    info "  /etc/wireguard/"
    info "  ├── warp.conf              ← used by wg-quick"
    info "  └── wgcf/"
    info "      ├── wgcf-account.toml  ← device credentials (keep safe)"
    info "      └── wgcf-profile.conf  ← raw wgcf output (backup)"
}

# ── step 6: install boot service ─────────────────────────────────────────────
install_boot_service() {
    step "Installing boot service (init: $INIT_SYSTEM)"

    case "$INIT_SYSTEM" in
    openrc)
        cat > /etc/init.d/warp-wgcf << 'EORC'
#!/sbin/openrc-run
description="Cloudflare WARP (wgcf WireGuard tunnel)"
depend() { need net; after net; }
start()  { ebegin "Starting WARP";  wg-quick up   warp; eend $?; }
stop()   { ebegin "Stopping WARP";  wg-quick down warp; eend $?; }
status() {
    ip link show warp &>/dev/null \
        && { einfo "WARP is up"; wg show warp; } \
        || { einfo "WARP is down"; return 1; }
}
EORC
        chmod +x /etc/init.d/warp-wgcf
        rc-update add warp-wgcf default
        success "OpenRC service → /etc/init.d/warp-wgcf"
        ;;
    runit)
        mkdir -p /etc/sv/warp-wgcf
        printf '#!/bin/sh\nwg-quick up warp\nexec sleep infinity\n' \
            > /etc/sv/warp-wgcf/run
        printf '#!/bin/sh\nwg-quick down warp 2>/dev/null || true\n' \
            > /etc/sv/warp-wgcf/finish
        chmod +x /etc/sv/warp-wgcf/run /etc/sv/warp-wgcf/finish
        ln -sf /etc/sv/warp-wgcf /var/service/
        success "runit service → /etc/sv/warp-wgcf"
        ;;
    sysvinit)
        cat > /etc/init.d/warp-wgcf << 'EOSYSV'
#!/bin/bash
### BEGIN INIT INFO
# Provides:          warp-wgcf
# Required-Start:    $network $remote_fs
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Cloudflare WARP (wgcf WireGuard tunnel)
### END INIT INFO
case "$1" in
  start)   wg-quick up   warp ;;
  stop)    wg-quick down warp ;;
  restart) wg-quick down warp 2>/dev/null; sleep 1; wg-quick up warp ;;
  status)
    ip link show warp &>/dev/null \
        && wg show warp \
        || { echo "WARP is down"; exit 1; }
    ;;
  *)       echo "Usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
EOSYSV
        chmod +x /etc/init.d/warp-wgcf
        update-rc.d warp-wgcf defaults
        success "sysvinit service → /etc/init.d/warp-wgcf"
        ;;
    *)
        warn "Unknown init — no boot service installed."
        warn "Bring up manually on reboot: wg-quick up ${WARP_IFACE}"
        ;;
    esac
}

# ── step 7: bring tunnel up + first verify ────────────────────────────────────
bring_up_and_verify() {
    step "Bringing up WireGuard tunnel: $WARP_IFACE"
    wg-quick up "$WARP_IFACE"
    sleep 2

    if ! ip link show "$WARP_IFACE" &>/dev/null; then
        die "Interface $WARP_IFACE did not come up.\nRun manually: wg-quick up $WARP_IFACE"
    fi
    success "Interface $WARP_IFACE is up"
    ip addr show "$WARP_IFACE" | grep 'inet ' | while IFS= read -r l; do info "  $l"; done

    info "Verifying tun proxy routes are intact:"
    ip route show default | grep 'dev tun' | while IFS= read -r l; do info "  $l"; done

    step "Verifying WARP tunnel (initial check)"
    local trace
    trace=$(curl -s --max-time 15 https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    if echo "$trace" | grep -q "warp=on"; then
        success "warp=on — traffic routing through Cloudflare WARP"
        echo "$trace" | grep -E "^(ip|warp|loc|colo)=" | while IFS= read -r l; do info "  $l"; done
    elif echo "$trace" | grep -q "warp=off"; then
        warn "warp=off — reached Cloudflare but not tunnelling yet."
        warn "Run: sudo ./wgcf-run.sh test"
    else
        warn "Could not reach Cloudflare trace — check network."
    fi
}

# ── summary ───────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD} Setup complete${RESET}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  ${CYAN}Interface  :${RESET} ${WARP_IFACE}  (WireGuard kernel — no tun slot used)"
    echo -e "  ${CYAN}Covers     :${RESET} ${PHYS_IFACE} via ${PHYS_GW}"
    echo -e "  ${CYAN}Untouched  :${RESET} tun0–tun11, all proxy policy tables"
    echo -e "  ${CYAN}Config     :${RESET} ${WARP_CONF}"
    echo -e "  ${CYAN}Account    :${RESET} ${WGCF_FINAL_DIR}/wgcf-account.toml"
    echo -e "  ${CYAN}Init       :${RESET} ${INIT_SYSTEM} boot service installed"
    echo -e "  ${CYAN}Tier       :${RESET} $([[ -n "$WARP_LICENSE_KEY" ]] && echo "WARP+" || echo "Free")"
    echo ""
    echo -e "  ${BOLD}Daily control — use wgcf-run.sh:${RESET}"
    echo -e "  sudo ./wgcf-run.sh start    # bring tunnel up"
    echo -e "  sudo ./wgcf-run.sh stop     # bring tunnel down"
    echo -e "  sudo ./wgcf-run.sh restart  # cycle the tunnel"
    echo -e "  sudo ./wgcf-run.sh status   # interface + handshake info"
    echo -e "  sudo ./wgcf-run.sh test     # verify warp=on + show routes"
    echo ""
    echo -e "  ${BOLD}Re-run setup (cleans state first):${RESET}"
    echo -e "  sudo ./warp-wgcf-setup.sh"
    echo ""
    echo -e "  ${BOLD}Full uninstall:${RESET}"
    echo -e "  sudo ./warp-wgcf-setup.sh --uninstall"
    echo ""
    if [[ -z "$WARP_LICENSE_KEY" ]]; then
        echo -e "  ${YELLOW}WARP+ upgrade:${RESET} get key from 1.1.1.1 app → Account → Key, then:"
        echo -e "  WARP_LICENSE_KEY=your-key sudo ./warp-wgcf-setup.sh"
        echo ""
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    # Handle --uninstall before anything else
    if [[ "${1:-}" == "--uninstall" ]]; then
        require_root
        full_uninstall
    fi

    echo -e "${BOLD}${BLUE}"
    echo "  ██╗    ██╗ █████╗ ██████╗ ██████╗ "
    echo "  ██║    ██║██╔══██╗██╔══██╗██╔══██╗"
    echo "  ██║ █╗ ██║███████║██████╔╝██████╔╝"
    echo "  ██║███╗██║██╔══██║██╔══██╗██╔═══╝ "
    echo "  ╚███╔███╔╝██║  ██║██║  ██║██║     "
    echo "   ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     "
    echo -e "${RESET}  Cloudflare WARP via wgcf — setup"
    echo ""

    require_root
    detect_init
    detect_physical_route
    cleanup              # always clean first — ensures fresh state
    install_deps
    install_wgcf
    generate_config
    patch_config
    verify_structure
    install_boot_service
    bring_up_and_verify
    print_summary
}

main "$@"
