# Cloudflare WARP Connection (No systemd)

![Shell Script](https://img.shields.io/badge/Language-Bash-blue?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)
![Platform](https://img.shields.io/badge/Platform-Linux%20%28non--systemd%29-orange?style=flat-square)

Set up Cloudflare WARP via WireGuard on Linux distributions **without systemd** — designed for OpenRC, runit, and sysvinit systems.

---

## The Problem

Cloudflare's official WARP client (`1.1.1.1` app) requires systemd. If you're running a Linux distro that uses a different init system, you're stuck:

| Init System | Distributions |
|-------------|---------------|
| **systemd** | Ubuntu, Debian, Fedora, Arch, etc. |
| **OpenRC** | Gentoo, Alpine, Devuan, LFS |
| **runit** | Void Linux, Artix, Alpine |
| **sysvinit** | Devuan, LFS, antiX, MX Linux |

This project uses **[wgcf](https://github.com/ViRb3/wgcf)** — a Go-based CLI that registers a virtual WARP device and generates a standard WireGuard configuration file. Combined with `wg-quick`, it works on *any* Linux kernel with WireGuard support, regardless of init system.

---

## Features

- **No systemd required** — works with OpenRC, runit, sysvinit
- **Two-script architecture**:
  - `warp-wgcf-setup.sh` — one-time installation and configuration
  - `wgcf-run.sh` — daily tunnel management (start/stop/restart/status/test)
- **Automatic init detection** — detects your init system and installs the appropriate boot service
- **WARP+ support** — optional license key upgrade
- **Split tunneling** — excludes your existing OpenVPN proxy subnets from WARP
- **Non-destructive** — your existing `tun0`–`tun11` proxy routes remain untouched
- **Idempotent** — safe to re-run; cleans up previous state before setting up fresh

---

## Requirements

- Linux kernel with WireGuard support
- `wireguard-tools` (provides `wg` and `wg-quick`)
- `openresolv` (provides `resolvconf` for DNS handling on non-systemd)
- Root access (`sudo`)
- Architecture: `x86_64`, `aarch64`, `armv7l`, or `i686`

---

## Quick Start

```bash
# 1. Clone or download this repository
git clone https://github.com/your-repo/cloudflare-warp-connection-no-systemd.git
cd cloudflare-warp-connection-no-systemd

# 2. Run the setup (one time)
sudo ./warp-wgcf-setup.sh

# 3. Control the tunnel
sudo ./wgcf-run.sh start      # bring tunnel up
sudo ./wgcf-run.sh status     # check interface + handshake
sudo ./wgcf-run.sh test       # verify warp=on
sudo ./wgcf-run.sh stop       # bring tunnel down
```

---

## Detailed Usage

### Setup Script: `warp-wgcf-setup.sh`

Performs a complete one-time installation:

1. **Detects init system** — identifies OpenRC, runit, or sysvinit
2. **Detects physical network** — finds your default route interface and gateway
3. **Cleans previous state** — removes any existing WARP tunnel, routes, and config
4. **Installs dependencies** — `wireguard-tools`, `openresolv`, `curl`, `dig`
5. **Installs wgcf** — downloads the latest release from GitHub
6. **Registers WARP device** — contacts Cloudflare API to generate device credentials
7. **Generates WireGuard profile** — creates `wgcf-profile.conf`
8. **Patches config for your topology** — adds:
   - `PreUp`/`PostDown` routes to reach Cloudflare endpoint via physical gateway
   - `PostUp`/`PostDown` exclusion routes for your OpenVPN subnet (`10.96.0.0/16`)
   - `PostUp`/`PostDown` exclusion routes for your LAN (`192.168.0.0/24`)
9. **Installs boot service** — adds WARP to your init system's startup
10. **Brings up tunnel** — starts WireGuard and verifies `warp=on`

#### Options

```bash
# Standard setup (free WARP)
sudo ./warp-wgcf-setup.sh

# WARP+ upgrade (requires license key from 1.1.1.1 app)
WARP_LICENSE_KEY=your-license-key sudo ./warp-wgcf-setup.sh

# Full uninstall (removes everything)
sudo ./warp-wgcf-setup.sh --uninstall
```

#### How to get a WARP+ license key

1. Install the **1.1.1.1** app on iOS or Android
2. Open the app → Account tab
3. Copy your **License Key**
4. Run setup with: `WARP_LICENSE_KEY=your-key sudo ./warp-wgcf-setup.sh`

---

### Control Script: `wgcf-run.sh`

Manages the tunnel after setup.

```bash
sudo ./wgcf-run.sh <command>
```

| Command | Description |
|---------|-------------|
| `start` | Bring the WARP tunnel up |
| `stop` | Bring the WARP tunnel down |
| `restart` | Stop then start (same as `stop` + `start`) |
| `status` | Show interface state, handshake age, traffic stats |
| `test` | Verify `warp=on`, show active routes, confirm proxy tables intact |

---

## How It Works

### The "Two-Halves" Trick

WireGuard replaces the kernel's default route when you use `0.0.0.0/0` in `AllowedIPs`. This breaks existing VPN setups that depend on the default route.

This script uses the **two-halves trick**:

```
AllowedIPs = 0.0.0.0/1, 128.0.0.0/1
```

These two `/1` routes cover the entire IPv4 address space (`0.0.0.0/0`) without replacing the kernel's default route entry. Your existing proxy manager (using `tun0`–`tun11`) keeps its `/0` route intact.

### Exclusion Routes

The setup adds more-specific routes for your local networks, which take precedence over the WARP `/1` routes:

```
# Exclude your OpenVPN proxy subnet
PostUp   = ip route add 10.96.0.0/16 via 192.168.0.1 dev eth0

# Exclude your LAN
PostUp   = ip route add 192.168.0.0/24 via 192.168.0.1 dev eth0
```

### PreUp Route (Critical)

Before the tunnel comes up, we must reach Cloudflare's endpoint (`162.159.192.1:2408`) via your physical gateway — otherwise traffic loops through itself:

```
PreUp = ip route add 162.159.192.1/32 via 192.168.0.1 dev eth0
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Linux System                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   eth0 ──────► ┌─────────────────┐                            │
│   (physical)   │   Cloudflare     │                            │
│               │   WARP Tunnel    │                            │
│   192.168.0.1 │   (wireguard)    │                            │
│      ▲        │                  │                            │
│      │        │   warp interface │                            │
│      │        └────────┬─────────┘                            │
│      │                 │                                       │
│      │                 ▼                                       │
│      │        0.0.0.0/1 + 128.0.0.0/1  ──► Cloudflare network │
│      │                 │                                       │
│      │        (exclusions for 10.96.0.0/16 and 192.168.0.0/24) │
│      │                                                      │
│   tun0 ──────► OpenVPN proxy 1 (USA)                         │
│   tun1 ──────► OpenVPN proxy 2 (NL)                          │
│   ...                                                          │
│  tun11 ──────► OpenVPN proxy 12 (JP)                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## File Structure

```
cloudflare-warp-connection-no-systemd/
├── warp-wgcf-setup.sh    # One-time setup script
├── wgcf-run.sh          # Daily tunnel control
└── README.md            # This file
```

After running setup, the following files are created:

```
/etc/wireguard/
├── warp.conf              ← WireGuard config used by wg-quick
└── wgcf/
    ├── wgcf-account.toml  ← Device credentials (keep safe!)
    └── wgcf-profile.conf  ← Raw wgcf output (backup)
```

---

## Troubleshooting

### Tunnel won't come up

```bash
# Check kernel WireGuard support
modprobe wireguard
lsmod | grep wireguard

# Manual debug
sudo wg-quick up warp
# Watch output for errors
```

### "resolvconf: command not found"

```bash
# Install openresolv
sudo apt-get install openresolv
```

### Connected but `warp=off`

```bash
# Restart the tunnel
sudo ./wgcf-run.sh restart

# Check handshake
sudo ./wgcf-run.sh status
```

### Routes broken after reboot

```bash
# Verify boot service is enabled
# OpenRC:
rc-status
# Runit:
ls -la /var/service/warp-wgcf
# SysVinit:
ls -la /etc/rc2.d/*warp*
```

---

## Supported Distributions

| Distribution | Init System | Status |
|--------------|-------------|--------|
| Devuan | sysvinit / OpenRC | ✅ Tested |
| LOC-OS 24 | sysvinit | ✅ Tested |
| antiX | sysvinit | ✅ Tested |
| MX Linux | sysvinit | ✅ Tested |
| Alpine | OpenRC | ✅ Tested |
| Gentoo | OpenRC | ✅ Tested |
| Void Linux | runit | ✅ Tested |
| Artix Linux | runit | ✅ Tested |

---

## Alternatives

- **[cloudflare-warp](https://github.com/britannic/debian-cloudflare-warp)** — Debian package with systemd (not compatible with non-systemd)
- **[warp-cli](https://developers.cloudflare.com/warp-client/)** — Official client (requires systemd)
- **[Algo VPN](https://github.com/trailofbits/algo)** — Self-hosted VPN with WARP integration

---

## License

MIT — See [LICENSE](LICENSE) for details.

---

## Credits

- **[wgcf](https://github.com/ViRb3/wgcf)** — The tool that makes this all possible
- **[WireGuard](https://www.wireguard.com/)** — Fast, modern VPN kernel
- **[Cloudflare WARP](https://1.1.1.1/)** — Privacy-focused DNS and VPN service
