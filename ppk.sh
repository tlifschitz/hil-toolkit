#!/usr/bin/env bash
# Nordic PPK2 power profiler (source-meter mode) — DUT current draw + session-scoped supply.
#
#   ./ppk.sh info                     # identity + calibration (1st line is doctor-friendly)
#   ./ppk.sh avg [secs] [--power]     # mean/min/max current over secs (default 5)
#   ./ppk.sh measure <secs> [-o f.csv] [--avg N] [--power] [--plot]  # CSV: t_s,current_uA,logic
#   ./ppk.sh plot <f.csv> [-o f.png]  # envelope plot of a capture (no hardware needed)
#   ./ppk.sh reset                    # recover a wedged PPK2 (opcode reset, ~3 s re-enum)
#   ./ppk.sh selftest                 # pure-math checks, no hardware
#
# Power semantics (instrument-imposed): the PPK2 resets when its port closes, so
# the source rail is only up WHILE a session holds it — same as the Nordic app.
# --power supplies the DUT at PPK_VOLTAGE_MV for the session, rail drops at exit.
# Sessions back-to-back are fine: the wrapper + driver wait out the ~3 s
# re-enumeration that follows every session close.
# Full-rate CSV is 100k rows/s — use --avg 100 for a 1 kHz file on long captures.
# Needs numpy + pyserial under PPK_PYTHON — point it at a venv if the system
# python3 lacks them.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hil_load_env

PPK_PYTHON="${PPK_PYTHON:-python3}"
PPK_VOLTAGE_MV="${PPK_VOLTAGE_MV:-3300}"
if [ -z "${PPK_PORT:-}" ]; then
    PPK_PORT="$(ls /dev/serial/by-id/usb-Nordic_Semiconductor_PPK2_*-if01 2>/dev/null | head -1 || true)"
fi

cmd="${1:-info}"
if [ "$cmd" != "selftest" ]; then
    command -v "$PPK_PYTHON" >/dev/null 2>&1 || hil_die "$PPK_PYTHON not found — set PPK_PYTHON in dut.env"
    "$PPK_PYTHON" -c 'import numpy, serial; serial.Serial' >/dev/null 2>&1 \
        || hil_die "$PPK_PYTHON lacks numpy/pyserial — pip install, or point PPK_PYTHON at an env that has them"
fi
if [ "$cmd" != "selftest" ] && [ "$cmd" != "plot" ]; then    # plot works offline, on any CSV
    # the PPK2 re-enumerates (~3 s) after every session close — wait for the node
    for _ in $(seq 12); do
        [ -n "$PPK_PORT" ] && [ -e "$PPK_PORT" ] && break
        sleep 0.5
        [ -n "${PPK_PORT:-}" ] && [ -e "$PPK_PORT" ] \
            || PPK_PORT="$(ls /dev/serial/by-id/usb-Nordic_Semiconductor_PPK2_*-if01 2>/dev/null | head -1 || true)"
    done
    [ -n "$PPK_PORT" ] && [ -e "$PPK_PORT" ] \
        || hil_die "no PPK2 serial node (lsusb 1915:c00a?) — set PPK_PORT in dut.env if auto-discovery fails"
fi

exec "$PPK_PYTHON" "$HIL_DIR/ppk2.py" --port "$PPK_PORT" --mv "$PPK_VOLTAGE_MV" --run-dir "$RUN_DIR" "$@"
