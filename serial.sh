#!/usr/bin/env bash
# Non-interactive bridge to the device's serial console / CLI.
#
#   ./serial.sh start                 # detached reader: $PORT -> run/serial.log
#   ./serial.sh cmd <cli args...>     # send a CLI line, then show fresh output
#   ./serial.sh send <cli args...>    # send only (no tail)
#   ./serial.sh tail [n] | watch | log | stop | restart
#
# Reader and writer share the tty: the detached `cat` holds it open (keeping the
# raw termios from `stty`), while `send` writes "<line>\r\n" to TX.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hil_load_env
: "${SERIAL_PORT:?set SERIAL_PORT in dut.env (e.g. /dev/ttyUSB0)}"

LOG="$RUN_DIR/serial.log"
PIDF="$RUN_DIR/serial.reader.pid"
SETTLE="${SERIAL_SETTLE:-0.5}"

_running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

start() {
    [ -e "$SERIAL_PORT" ] || hil_die "no such port: $SERIAL_PORT (USB-UART adapter plugged in?)"
    if _running; then hil_info "reader already running (pid $(cat "$PIDF"))"; return; fi
    stty -F "$SERIAL_PORT" "$SERIAL_BAUD" raw -echo -echoe -echok -echonl -ixon -crtscts min 1 time 0
    setsid bash -c 'cat "$1" >> "$2"' _ "$SERIAL_PORT" "$LOG" </dev/null >/dev/null 2>&1 &
    echo $! > "$PIDF"
    hil_info "serial reader started (pid $(cat "$PIDF")) -> $LOG @ ${SERIAL_BAUD} 8N1"
}
stop()  { _running && kill "$(cat "$PIDF")" 2>/dev/null || true; rm -f "$PIDF"; hil_info "reader stopped"; }
send()  { [ -e "$SERIAL_PORT" ] || hil_die "no such port: $SERIAL_PORT"; printf '%s\r\n' "$*" > "$SERIAL_PORT"; }
_tail() { tail -n "${1:-40}" "$LOG" 2>/dev/null || true; }

case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    send)    shift; send "$@" ;;
    cmd)     shift; _running || hil_die "reader not running — ./serial.sh start"; send "$@"; sleep "$SETTLE"; _tail 30 ;;
    tail)    _tail "${2:-40}" ;;
    watch)   exec tail -f "$LOG" ;;
    log)     echo "$LOG" ;;
    *) echo "usage: serial.sh {start|stop|restart|send <cli...>|cmd <cli...>|tail [n]|watch|log}" >&2; exit 2 ;;
esac
