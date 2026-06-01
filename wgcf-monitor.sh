#!/usr/bin/env bash
# =============================================================================
# wgcf-monitor.sh  —  WARP CONNECTION MONITOR (daemon)
#
# Runs as a background daemon. Every 45 seconds tests if WARP is receiving
# data by making a 12-second HTTP request through the tunnel. If the test
# fails, triggers a restart via wgcf-run.sh.
#
# wgcf-run.sh must be in the same directory as this script.
#
# USAGE:
#   sudo ./wgcf-monitor.sh start    — start the monitor daemon
#   sudo ./wgcf-monitor.sh stop     — stop the monitor daemon
#   sudo ./wgcf-monitor.sh status   — show if daemon is running + last log lines
#   sudo ./wgcf-monitor.sh log      — tail the full monitor log
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
die()     { echo -e "${RED}[error]${RESET} $*" >&2; exit 1; }

# ── config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="${SCRIPT_DIR}/wgcf-run.sh"

WARP_IFACE="warp"
CHECK_INTERVAL=45       # seconds between connection tests
CHECK_TIMEOUT=12        # seconds to wait for the test request
TEST_URL="https://cloudflare.com/cdn-cgi/trace"

PID_FILE="/var/run/wgcf-monitor.pid"
LOG_FILE="/var/log/wgcf-monitor.log"

# ── helpers ───────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0 $*"
}

require_run_script() {
    [[ -x "$RUN_SCRIPT" ]] || \
        die "wgcf-run.sh not found or not executable at: ${RUN_SCRIPT}\nEnsure both scripts are in the same directory."
}

log() {
    # Write timestamped entry to log file and stdout
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${ts}] $*" | tee -a "$LOG_FILE"
}

is_running() {
    # Returns 0 if daemon is running, 1 if not
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# ── connection test ───────────────────────────────────────────────────────────
# Returns 0 if WARP is receiving data, 1 if not.
# Tests by fetching Cloudflare's trace endpoint through the warp interface.
# --interface binds the request to the warp device — if traffic is actually
# flowing through the tunnel this succeeds; if the tunnel is dead it times out.
test_connection() {
    local result
    result=$(curl -s \
        --max-time "$CHECK_TIMEOUT" \
        --interface "$WARP_IFACE" \
        "$TEST_URL" \
        2>/dev/null || true)

    # Check we got actual WARP data back, not just any response
    if echo "$result" | grep -q "warp="; then
        return 0
    fi
    return 1
}

# ── daemon loop ───────────────────────────────────────────────────────────────
run_daemon() {
    log "Monitor started — PID $$  interval=${CHECK_INTERVAL}s  timeout=${CHECK_TIMEOUT}s"
    log "Run script: ${RUN_SCRIPT}"
    log "Test URL:   ${TEST_URL}"

    local consecutive_failures=0

    while true; do
        sleep "$CHECK_INTERVAL"

        # Skip test if interface is not even up — trigger restart directly
        if ! ip link show "$WARP_IFACE" &>/dev/null; then
            consecutive_failures=$(( consecutive_failures + 1 ))
            log "FAIL  — interface '$WARP_IFACE' is not up (failure #${consecutive_failures})"
            trigger_restart
            consecutive_failures=0
            continue
        fi

        # Run the connection test
        if test_connection; then
            consecutive_failures=0
            log "OK    — WARP is receiving data"
        else
            consecutive_failures=$(( consecutive_failures + 1 ))
            log "FAIL  — no data through WARP within ${CHECK_TIMEOUT}s (failure #${consecutive_failures})"
            trigger_restart
            consecutive_failures=0
        fi
    done
}

trigger_restart() {
    log "RESTART — calling wgcf-run.sh restart"
    if bash "$RUN_SCRIPT" restart >> "$LOG_FILE" 2>&1; then
        log "RESTART — completed successfully"
    else
        log "RESTART — wgcf-run.sh restart returned an error (see above)"
    fi
}

# ── commands ──────────────────────────────────────────────────────────────────
cmd_start() {
    require_run_script

    # ── Atomic check-and-set using mkdir mutex (POSIX, no flock dependency) ──
    local LOCK_DIR="/var/run/wgcf-monitor.lock"
    mkdir "$LOCK_DIR" 2>/dev/null || {
        local pid
        [[ -f "$PID_FILE" ]] && pid=$(cat "$PID_FILE") || pid="unknown"
        die "Monitor is already running (PID ${pid}).\nStop it first: sudo ./wgcf-monitor.sh stop"
    }
    # Clean up the mutex when this cmd_start process exits (normal or error)
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

    info "Starting WARP monitor daemon..."
    info "  Interval : ${CHECK_INTERVAL}s"
    info "  Timeout  : ${CHECK_TIMEOUT}s"
    info "  Log      : ${LOG_FILE}"
    info "  PID file : ${PID_FILE}"

    # Launch daemon: nohup + double-fork so it survives the calling terminal.
    # The guard at the bottom of this script prevents main() from executing
    # when sourced — only function definitions are imported.
    nohup bash -c "
        source '${BASH_SOURCE[0]}'
        run_daemon
    " >> "$LOG_FILE" 2>&1 &

    local daemon_pid=$!
    echo "$daemon_pid" > "$PID_FILE"
    chmod 644 "$PID_FILE"

    sleep 1

    if is_running; then
        success "Monitor daemon started (PID ${daemon_pid})"
        info "Tail log: sudo ./wgcf-monitor.sh log"
    else
        # Release lock before dying so the user can retry
        rmdir "$LOCK_DIR" 2>/dev/null || true
        die "Daemon did not stay running. Check: $LOG_FILE"
    fi
}

cmd_stop() {
    if ! is_running; then
        warn "Monitor is not running."
        exit 0
    fi

    local pid; pid=$(cat "$PID_FILE")
    info "Stopping monitor daemon (PID ${pid})..."

    kill "$pid" 2>/dev/null || true
    sleep 1

    # Force kill if still alive
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    rm -f "$PID_FILE"

    log "Monitor stopped (was PID ${pid})"
    success "Monitor stopped."
}

cmd_status() {
    echo ""
    if is_running; then
        local pid; pid=$(cat "$PID_FILE")
        success "Monitor is RUNNING (PID ${pid})"
        info "  Interval : ${CHECK_INTERVAL}s"
        info "  Timeout  : ${CHECK_TIMEOUT}s"
        info "  Log      : ${LOG_FILE}"
    else
        warn "Monitor is NOT running."
        info "Start with: sudo ./wgcf-monitor.sh start"
    fi

    if [[ -f "$LOG_FILE" ]]; then
        echo ""
        info "Last 10 log entries:"
        tail -10 "$LOG_FILE" | while IFS= read -r l; do
            echo "  $l"
        done
    fi
    echo ""
}

cmd_log() {
    [[ -f "$LOG_FILE" ]] || { warn "No log file yet at ${LOG_FILE}"; exit 0; }
    info "Tailing ${LOG_FILE} (Ctrl+C to stop):"
    echo ""
    tail -f "$LOG_FILE"
}

usage() {
    echo ""
    echo -e "${BOLD}wgcf-monitor.sh${RESET} — Cloudflare WARP connection monitor"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET} sudo ./wgcf-monitor.sh <command>"
    echo ""
    echo -e "  ${CYAN}start${RESET}   start the monitor daemon"
    echo -e "  ${CYAN}stop${RESET}    stop the monitor daemon"
    echo -e "  ${CYAN}status${RESET}  show daemon state + last log entries"
    echo -e "  ${CYAN}log${RESET}     tail the live monitor log"
    echo ""
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"
    case "$cmd" in
        start)  require_root; cmd_start  ;;
        stop)   require_root; cmd_stop   ;;
        status) require_root; cmd_status ;;
        log)    require_root; cmd_log    ;;
        *)      usage; exit 0 ;;
    esac
}

# Guard: only run main() when EXECUTED directly, not when SOURCED.
# The daemon launch (line 150) sources this script to get function
# definitions, but without this guard, main() would execute with no
# arguments and exit — killing the daemon before run_daemon runs.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
