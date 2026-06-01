# PRD — Stability & Security: Cloudflare WARP WireGuard Tunnel

**Version:** 1.1  
**Date:** 2026-06-01  
**Status:** Draft  
**Scope:** Routing table resilience + DNS isolation for single WARP WireGuard tunnel
**Applies to:** `warp-wgcf-setup.sh`, `wgcf-run.sh`, `wgcf-monitor.sh`

---

## 1. Executive Summary

Two attack surfaces determine whether this system is stable or a paperweight: **routing table contamination** and **DNS hijacking**. This document specifies the patterns, failure modes, verification criteria, and enforcement mechanisms for the Cloudflare WARP WireGuard tunnel on non-systemd Linux.

The core insight: **any code path that mutates shared kernel state (routing tables, iptables, `/etc/resolv.conf`) is a stability risk. Any code path that allows non-WARP DNS resolution is a security risk.** The patterns below enforce correctness at both the routing and DNS layers.

This project deploys a single Cloudflare WARP WireGuard tunnel that coexists with an existing 12-slot OpenVPN proxy infrastructure (`tun0`–`tun11`). WARP covers the host's own unprotected egress traffic (`eth0`), while the OpenVPN proxy subnets (`10.96.0.0/16`) and LAN (`192.168.0.0/24`) are excluded via split-tunnel routing.

---

## 2. Routing Stability Patterns

### 2.1 Two-Halves Trick (WARP Coverage)

The WARP tunnel uses `AllowedIPs = 0.0.0.0/1, 128.0.0.0/1` instead of `0.0.0.0/0`. This covers the full IPv4 space without replacing the kernel's default route, preserving existing proxy routes in the `main` table.

| Route | Binary first octet | Range |
|-------|-------------------|-------|
| `0.0.0.0/1` | `0xxxxxxx` | `0.0.0.0` – `127.255.255.255` |
| `128.0.0.0/1` | `1xxxxxxx` | `128.0.0.0` – `255.255.255.255` |

Both `/1` routes are more specific than the kernel's `0.0.0.0/0` default, so they win in route selection. Exclusion routes (`10.96.0.0/16`, `192.168.0.0/24` via physical GW) are even MORE specific (`/16`, `/24`) and correctly take priority.

**Stability invariant:** The `/0` default route in the `main` table is never replaced — it is "shadowed" by the `/1` WARP routes and available as a fallback if WARP drops.

### 2.2 Split-Horizon Endpoint Route (PreUp)

Cloudflare's WARP endpoint (`162.159.192.1:2408`) must be reachable BEFORE the tunnel comes up. Without a direct route, the handshake packets would enter the tunnel itself — a routing loop.

```bash
# CORRECT — idempotent, no error suppression (fatal if fails)
PreUp = ip route replace ${endpoint_ip}/32 via ${PHYS_GW} dev ${PHYS_IFACE}
```

**Rule:** PreUp is CRITICAL. If it fails, the tunnel MUST NOT come up. Do NOT use `2>/dev/null || true`.

### 2.3 Exclusion Routes (PostUp)

VPN subnet and LAN traffic must stay on `eth0`, not enter the WARP tunnel. These are applied after the `/1` AllowedIPs routes are active — more specific, they win.

```bash
# idempotent, errors suppressed (non-critical — tunnel works without them)
PostUp = ip route replace ${SUBNET} via ${PHYS_GW} dev ${PHYS_IFACE} 2>/dev/null || true
```

**Rule:** PostUp routes are non-critical. Route replacement errors are acceptable — traffic would just go through WARP, which is suboptimal but not broken.

### 2.4 Route Manipulation Rules

| Rule | Rationale |
|------|-----------|
| **Use `ip route replace`, never `ip route add`** | Idempotent — no "File exists" errors on re-run |
| **Never suppress errors on PreUp** | Fatal if the endpoint route fails |
| **Suppress PostDown errors normally** | Route deletion may already have happened |
| **Never hardcode the gateway** | Use detected `$PHYS_GW` everywhere — networks differ |

**Anti-pattern (fixed):**
```bash
# WRONG — swallows ALL errors, tunnel comes up with broken routing
ip route add ... 2>/dev/null || true
```

### 2.5 Cleanup Idempotency

`cleanup()` in `warp-wgcf-setup.sh` runs before every setup. It must clean stale state from previous runs regardless of the network's actual gateway.

```bash
# CORRECT — uses detected PHYS_GW (works on any network)
ip route show | grep "/32.*via.*${PHYS_GW}" | ...
```

**Fixed bug:** Cleanup previously used hardcoded `KNOWN_PHYS_GW="192.168.0.1"` instead of detected `PHYS_GW`. On networks with different gateways (corporate: `10.0.0.x`, `172.16.0.x`), stale `/32` host routes were never cleaned — causing route accumulation on re-run.

### 2.6 Dead Route Detection

When the WARP tunnel drops (process killed, network change), routes pointing to the `warp` interface remain in the kernel as dead entries. Detection:

```bash
# Verify the warp interface exists before assuming routes are valid
ip link show warp >/dev/null 2>&1 || echo "WARP interface missing — routes may be dead"
```

The `wgcf-monitor.sh` daemon detects tunnel drops via connectivity tests and triggers a restart via `wgcf-run.sh restart`, which cycles the interface and regenerates routes.

---

## 3. DNS Management Patterns

### 3.1 resolv.conf Interaction

`wg-quick` uses `resolvconf` (provided by `openresolv`) to set DNS when the WARP interface comes up and restore previous DNS when it goes down. This is standard WireGuard behavior and handles DNS correctly for a single tunnel.

**What's safe:** The WARP config sets `DNS = 1.1.1.1, 1.0.0.1`. `wg-quick` calls `resolvconf` on `up`, which saves the previous state and sets Cloudflare DNS. On `down`, `resolvconf` restores the previous DNS.

**What's at risk:** If the host runs a local resolver (dnsmasq, Pi-hole, systemd-resolved stub), the DNS override may cause conflicts. This is a documentation gap, not a code bug — users with custom DNS setups should verify compatibility.

**DNS save/restore gap:** While `resolvconf` handles normal up/down correctly, a crash during tunnel startup could leave DNS in a mixed state. A manual save/restore mechanism is RECOMMENDED but NOT currently implemented.

### 3.2 DNS Isolation

This project does NOT modify host DNS beyond what `wg-quick` + `resolvconf` do. The existing OpenVPN proxy infrastructure handles its own DNS needs. WARP covers host egress traffic only — proxy DNS remains on its existing infrastructure.

---

## 4. Security Patterns

### 4.1 Kill Switch (Recommended, Not Implemented)

A kill switch guarantees: if the WARP tunnel drops, host traffic STOPS — it does NOT route through the unprotected physical interface.

```bash
# Block all OUTPUT on eth0 except WARP handshake and LAN
iptables -A OUTPUT -o eth0 -p udp --dport 2408 -d 162.159.192.0/24 -j ACCEPT  # WARP handshake
iptables -A OUTPUT -o eth0 -d 192.168.0.0/24 -j ACCEPT                          # LAN
iptables -A OUTPUT -o eth0 -j DROP                                              # Everything else
iptables -A OUTPUT -o warp -j ACCEPT                                            # WARP tunnel
```

**Status:** NOT implemented. The system currently relies on routing correctness (the `/1` routes shadow the default route). Adding a kill switch would make leak prevention explicit.

### 4.2 File Permission Security

WireGuard private keys, Cloudflare device tokens, and WARP+ license keys are stored in `/etc/wireguard/wgcf/wgcf-account.toml`. These MUST be readable only by root.

```bash
# CORRECT — permissions set atomically at file creation (no race window)
install -m 600 "$source" /etc/wireguard/wgcf/wgcf-account.toml
```

**Anti-pattern (fixed):**
```bash
# WRONG — race window between mv and chmod (file is umask-permissioned briefly)
mv "$source" /etc/wireguard/wgcf/wgcf-account.toml
chmod 600 /etc/wireguard/wgcf/wgcf-account.toml  # too late
```

### 4.3 PID File Atomicity

The monitor daemon's PID file must be written atomically to prevent two concurrent `start` commands from launching duplicate daemons.

```bash
# CORRECT — mkdir is atomic in POSIX, no race possible
LOCK_DIR="/var/run/wgcf-monitor.lock"
mkdir "$LOCK_DIR" 2>/dev/null || die "Monitor already running"
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
```

**Fixed bug:** Previous code checked `is_running` then wrote the PID file separately — a TOCTOU race window. Two simultaneous starts could both pass the check.

### 4.4 Process Group Cleanup

When stopping the monitor daemon, use process group signals to avoid orphaning child processes (e.g., `wg-quick` spawned by `trigger_restart`).

```bash
# CORRECT — kills the entire process group, not just the parent
kill -TERM -$pid   # negative PID = process group
```

**Status:** NOT implemented. Current code uses `kill $pid` (single process) followed by `kill -9 $pid` after 1s. Children may be orphaned.

---

## 5. Implementation Status

### 5.1 Scripts (this repo)

| Script | Lines | Purpose | Status |
|--------|-------|---------|--------|
| `warp-wgcf-setup.sh` | 635 | One-time WARP deployment + init boot service | ✅ Active |
| `wgcf-run.sh` | 259 | Daily tunnel control (start/stop/restart/status/test) | ✅ Active |
| `wgcf-monitor.sh` | 248 | Connection monitor daemon (auto-restart on failure) | ✅ Active (fixed C1) |

### 5.2 Bugs Fixed (2026-06-01 Audit)

| ID | Severity | Description | Fix |
|----|----------|-------------|-----|
| C1 | CRITICAL | Monitor daemon never started — `source` killed it via `main()` | Added `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard |
| H2 | HIGH | Route errors swallowed by `2>/dev/null \|\| true` | PreUp: `ip route replace` without suppression |
| H3 | HIGH | Cleanup used hardcoded `192.168.0.1` instead of detected `PHYS_GW` | Cleanup uses `$PHYS_GW` throughout |
| M1 | MEDIUM | Permission race window between `mv` and `chmod 600` | `install -m 600` (atomic) |
| M4 | MEDIUM | TOCTOU race on PID file (check then write) | `mkdir` mutex (atomic check-and-set) |

### 5.3 Remaining Gaps

| Priority | Gap | Impact |
|----------|-----|--------|
| HIGH | DNS save/restore on crash | `/etc/resolv.conf` could enter mixed state |
| HIGH | Kill switch (iptables per interface) | Host traffic could leak on tunnel drop |
| MEDIUM | Process group cleanup in monitor stop | Orphaned child processes |
| MEDIUM | Temp file uses `$$` instead of `mktemp` | `/tmp` symlink race on wgcf download |
| LOW | Physical interface detection misses `bond*`, `wwan*`, `br*` | Setup fails on uncommon interfaces |
| LOW | Monitor's `consecutive_failures` counter resets every iteration | No retry threshold logic |
| LOW | WARP+ license update not validated | Script reports success regardless |

---

## 6. Verification Checklist

Run after setup and periodically to verify system health:

```bash
# 1. WARP interface exists and has a handshake
sudo wg show warp | grep -E "interface|handshake|transfer"
# Expected: handshake within last 2 minutes, non-zero transfer

# 2. WARP is active (traffic routes through Cloudflare)
curl -s https://cloudflare.com/cdn-cgi/trace | grep warp
# Expected: warp=on

# 3. Two-halves routes are active
ip route show | grep -E "^0\.0\.0\.0/1|^128\.0\.0\.0/1"
# Expected: both routes present, dev warp

# 4. Exclusion routes work (VPN subnet + LAN bypass WARP)
ip route show 10.96.0.0/16 | grep -v warp
ip route show 192.168.0.0/24 | grep -v warp
# Expected: routes via physical interface, NOT warp

# 5. Physical default route is intact (fallback if WARP drops)
ip route show default | grep -v 'dev tun'
# Expected: default route exists via eth0/enp*/etc.

# 6. Monitor daemon is running (if enabled)
sudo ./wgcf-monitor.sh status
# Expected: "Monitor is running (PID XXXX)"

# 7. No DNS hijacking — resolv.conf uses expected nameservers
grep nameserver /etc/resolv.conf
# Expected: Cloudflare DNS (1.1.1.1, 1.0.0.1) or pre-WARP config

# 8. WireGuard config permissions are restrictive
stat -c "%a %n" /etc/wireguard/warp.conf /etc/wireguard/wgcf/wgcf-account.toml
# Expected: 600 for both files
```

---

## 7. References

- [WireGuard Quick Start](https://www.wireguard.com/quickstart/) — `wg-quick`, `wg`, config format
- [wgcf](https://github.com/ViRb3/wgcf) — Cloudflare WARP registration and WireGuard profile generation
- [Cloudflare WARP documentation](https://developers.cloudflare.com/warp-client/) — WARP protocol, endpoint IPs
- [ip-route(8) man page](https://man7.org/linux/man-pages/man8/ip-route.8.html) — `ip route replace`, routing table management
- [resolvconf(8)](https://manpages.debian.org/unstable/openresolv/resolvconf.8.en.html) — DNS management via `openresolv`
- [wg-quick(8)](https://manpages.debian.org/unstable/wireguard-tools/wg-quick.8.en.html) — WireGuard tunnel manager, PreUp/PostUp/PostDown
- [Linux Advanced Routing & Traffic Control HOWTO](https://lartc.org/howto/) — RPDB, policy routing
