#!/usr/bin/env bash
# Shared helpers for the HIL toolkit. Source this from the <area>.sh wrappers;
# do NOT execute directly.
#
# Self-contained: device coordinates come from dut.env (gitignored); the debug
# probe is driven by probe-rs, everything else by stdlib tools.

HIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RUN_DIR="$HIL_DIR/run"
mkdir -p "$RUN_DIR"

hil_die()  { echo "hil: ERROR: $*" >&2; exit 1; }
hil_info() { echo "hil: $*" >&2; }

# ---- environment ----------------------------------------------------------
hil_load_env() {
    local env_file="${DUT_ENV:-$HIL_DIR/dut.env}"
    [ -f "$env_file" ] || hil_die "missing $env_file — copy dut.env.example to dut.env and fill it in"
    set -a; . "$env_file"; set +a   # shellcheck disable=SC1090

    : "${PROBE_RS:=probe-rs}"
    : "${GDB:=arm-none-eabi-gdb}"
    : "${GDB_PORT:=1337}"
    : "${SERIAL_BAUD:=115200}"

    # Firmware paths are relative to the project root (the directory holding this
    # toolkit) unless absolute, so a dut.env can stay portable across checkouts.
    # Nothing is required here — the instrument wrappers (scope, ppk) need no
    # target at all; the probe wrappers demand what they use, where they use it.
    PROJECT_DIR="${PROJECT_DIR:-$(dirname "$HIL_DIR")}"
    : "${FIRMWARE:=}"
    : "${FLASH_IMAGE:=$FIRMWARE}"
    case "$FIRMWARE"    in ""|/*) ;; *) FIRMWARE="$PROJECT_DIR/$FIRMWARE" ;; esac
    case "$FLASH_IMAGE" in ""|/*) ;; *) FLASH_IMAGE="$PROJECT_DIR/$FLASH_IMAGE" ;; esac
}

hil_require_firmware() {
    [ -n "$FIRMWARE" ] || hil_die "set FIRMWARE in dut.env (the ELF: gdb symbols + RTT control block)"
    [ -f "$FIRMWARE" ] || hil_die "no ELF: $FIRMWARE — build first"
}

# probe-rs target selection, shared by every probe op -> $PROBE_ARGS. PROBE
# (VID:PID[:serial]) is only needed when more than one probe is plugged in.
hil_probe_args() {
    [ -n "${CHIP:-}" ] || hil_die "set CHIP in dut.env (probe-rs target name; list them: $PROBE_RS chip list)"
    PROBE_ARGS=(--chip "$CHIP")
    [ -n "${PROBE:-}" ] && PROBE_ARGS+=(--probe "$PROBE")
    return 0
}

# ---- single-probe arbitration ---------------------------------------------
# One probe serves flash, gdb and RTT — only one at a time. Long-lived sessions
# (gdb server, RTT attach) record "<pid> <owner>" here; one-shot ops refuse while
# a session holds it, instead of failing deep inside probe-rs with a locked probe.
PROBE_PIDF_NAME="probe.pid"

_hil_probe_pidf() { echo "$RUN_DIR/$PROBE_PIDF_NAME"; }

hil_probe_held() {
    local f; f="$(_hil_probe_pidf)"
    [ -f "$f" ] && kill -0 "$(cut -d' ' -f1 <"$f")" 2>/dev/null
}
hil_probe_owner() { cut -d' ' -f2- <"$(_hil_probe_pidf)" 2>/dev/null; }

hil_probe_require_free() {
    if hil_probe_held; then
        hil_die "probe busy (held by $(hil_probe_owner)) — stop it first: $(hil_probe_owner).sh stop"
    fi
    rm -f "$(_hil_probe_pidf)"
}
hil_probe_claim() { echo "$1 $2" > "$(_hil_probe_pidf)"; }   # <pid> <owner>
hil_probe_release() {
    if hil_probe_held; then kill "$(cut -d' ' -f1 <"$(_hil_probe_pidf)")" 2>/dev/null || true; fi
    rm -f "$(_hil_probe_pidf)"
}
