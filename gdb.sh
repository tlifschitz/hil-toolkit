#!/usr/bin/env bash
# Scripted (batch) on-target inspection: probe-rs gdb server + arm-none-eabi-gdb.
# Not for live single-stepping — for "halt, look, resume" automation.
#
#   ./gdb.sh server start | server stop
#   ./gdb.sh bt                       # halt, backtrace, resume
#   ./gdb.sh inspect <expr> [expr...] # halt, print exprs, resume
#   ./gdb.sh break <fn>               # break, continue until hit, backtrace (left halted)
#   ./gdb.sh exec <gdb -ex args...>   # raw batch passthrough
#
# Connecting a gdb client halts the core and detaching resumes it, so every
# batch below ends in 'detach' — a batch that dies without detaching leaves the
# target halted. The server stays up between calls and holds the probe, so RTT
# and flashing refuse while it runs.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hil_load_env
hil_require_firmware

server_start() {
    if hil_probe_held && [ "$(hil_probe_owner)" = "gdb" ]; then return 0; fi
    hil_probe_require_free
    hil_probe_args
    setsid "$PROBE_RS" gdb "${PROBE_ARGS[@]}" --gdb-connection-string "127.0.0.1:$GDB_PORT" \
        </dev/null >>"$RUN_DIR/gdbserver.log" 2>&1 &
    hil_probe_claim $! gdb
    sleep 1
    hil_probe_held || hil_die "probe-rs gdb failed to start (see $RUN_DIR/gdbserver.log)"
    hil_info "gdb server on :$GDB_PORT"
}

run_batch() { "$GDB" -q -nx -batch -ex "target extended-remote :$GDB_PORT" "$@" "$FIRMWARE"; }

cmd="${1:-}"; shift || true
case "$cmd" in
    server) case "${1:-}" in
                start) server_start ;;
                stop)  hil_probe_release; hil_info "gdb server stopped" ;;
                *) echo "usage: gdb.sh server {start|stop}" >&2; exit 2 ;;
            esac ;;
    bt)      server_start; run_batch -ex "bt" -ex "detach" ;;
    inspect) server_start
             args=(); for e in "$@"; do args+=(-ex "print $e"); done
             args+=(-ex "detach"); run_batch "${args[@]}" ;;
    break)   [ -n "${1:-}" ] || hil_die "usage: gdb.sh break <fn>"
             server_start; run_batch -ex "break $1" -ex "continue" -ex "bt" ;;
    exec)    server_start; run_batch "$@" ;;
    stop)    hil_probe_release; hil_info "gdb server stopped" ;;
    *) echo "usage: gdb.sh {server start|server stop|bt|inspect <expr...>|break <fn>|exec <args...>|stop}" >&2; exit 2 ;;
esac
