#!/usr/bin/env bash
# Capture SEGGER RTT firmware logs via probe-rs (attach = connect without
# reflashing or resetting; RTT goes to stdout, we tee it into a log).
#
#   ./rtt.sh start | stop | tail [n] | watch | log
#
# The ELF is needed to locate the RTT control block. The session holds the probe,
# so flashing and gdb refuse while it runs — stop RTT before those.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hil_load_env
hil_require_firmware

LOG="$RUN_DIR/rtt.log"

start() {
    if hil_probe_held && [ "$(hil_probe_owner)" = "rtt" ]; then hil_info "RTT already running"; return; fi
    hil_probe_require_free
    hil_probe_args
    setsid "$PROBE_RS" attach "${PROBE_ARGS[@]}" "$FIRMWARE" \
        </dev/null >>"$LOG" 2>&1 &
    hil_probe_claim $! rtt
    sleep 1
    hil_probe_held || hil_die "probe-rs attach failed — see $LOG"
    hil_info "RTT capturing -> $LOG"
}

case "${1:-}" in
    start) start ;;
    stop)  hil_probe_release; hil_info "RTT stopped" ;;
    tail)  tail -n "${2:-40}" "$LOG" 2>/dev/null || true ;;
    watch) exec tail -f "$LOG" ;;
    log)   echo "$LOG" ;;
    *) echo "usage: rtt.sh {start|stop|tail [n]|watch|log}" >&2; exit 2 ;;
esac
