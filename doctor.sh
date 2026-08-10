#!/usr/bin/env bash
# Preflight: report what's ready and what's missing. Read-only, safe anytime.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hil_load_env

ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

echo "== host tools =="
for t in "$PROBE_RS" "$GDB" python3 stty; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t missing"; fi
done

echo "== debug probe =="
if hil_probe_held; then
    ok "probe held by the $(hil_probe_owner) session"
elif probes="$("$PROBE_RS" list 2>/dev/null)" && [ -n "$probes" ]; then
    printf '%s\n' "$probes" | sed 's/^/  ok   /'
else
    warn "no probe found ($PROBE_RS list) — board unplugged, or udev rules missing"
fi
if [ -z "${CHIP:-}" ]; then warn "CHIP unset in dut.env"
elif "$PROBE_RS" chip list 2>/dev/null | grep -qiFx "$CHIP"; then ok "target $CHIP known to probe-rs"
else warn "target '$CHIP' not in '$PROBE_RS chip list' — check the exact spelling"; fi

echo "== serial =="
if [ -n "${SERIAL_PORT:-}" ] && [ -e "${SERIAL_PORT:-}" ]; then ok "SERIAL_PORT $SERIAL_PORT present"
elif [ -n "${SERIAL_PORT:-}" ]; then warn "SERIAL_PORT $SERIAL_PORT set but not present (unplugged?)"
else warn "SERIAL_PORT unset in dut.env"; fi

echo "== firmware =="
if [ -z "$FIRMWARE" ]; then warn "FIRMWARE unset in dut.env"
else
    [ -f "$FIRMWARE" ]    && ok "elf $FIRMWARE"      || warn "no $FIRMWARE — run ./build.sh"
    [ -f "$FLASH_IMAGE" ] && ok "image $FLASH_IMAGE" || warn "no $FLASH_IMAGE — run ./build.sh"
fi

echo "== scope (Rigol USBTMC) =="
scope_dev="${SCOPE_DEV:-/dev/usbtmc0}"
if [ ! -e "$scope_dev" ]; then warn "no $scope_dev — scope off, or kernel usbtmc not bound"
elif [ ! -r "$scope_dev" ] || [ ! -w "$scope_dev" ]; then warn "$scope_dev not r/w — add the udev rule (see README) or use sudo"
elif idn="$(timeout 5 "$HIL_DIR/scope.sh" idn 2>/dev/null)" && [ -n "$idn" ]; then ok "responds: $idn"
else warn "$scope_dev present but no *IDN? reply"; fi

echo "== PPK2 (Nordic power profiler) =="
# the PPK2 re-enumerates for ~3 s after every ppk.sh session — retry once
lsusb 2>/dev/null | grep -qi '1915:c00a' || sleep 3
if lsusb 2>/dev/null | grep -qi '1915:c00a'; then
    ok "PPK2 on USB (1915:c00a)"
    if info="$(timeout 10 "$HIL_DIR/ppk.sh" info 2>/dev/null | head -1)" && [ -n "$info" ]; then
        ok "responds: $info"
    else warn "PPK2 present but no metadata reply (PPK_PYTHON deps missing, or port busy)"; fi
else warn "no PPK2 (1915:c00a) on USB"; fi
