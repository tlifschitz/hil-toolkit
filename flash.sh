#!/usr/bin/env bash
# Flash the target through the debug probe (probe-rs), then reset and run.
#
#   ./flash.sh              # build (build.sh) + flash $FLASH_IMAGE
#   ./flash.sh fw.elf       # flash this image as-is, skip the build
#
# ELF/hex images carry their own load addresses. A raw .bin does not, so it is
# flashed at $FLASH_ADDR (default 0x0) — override for projects with a bootloader.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hil_load_env

IMAGE="${1:-$FLASH_IMAGE}"
[ -n "$IMAGE" ] || hil_die "set FIRMWARE (or FLASH_IMAGE) in dut.env, or pass an image"

# Building on the no-arg path is what keeps you from flashing a stale image.
if [ $# -eq 0 ]; then "$HIL_DIR/build.sh"; fi
[ -f "$IMAGE" ] || hil_die "image not found: $IMAGE"

hil_probe_require_free
hil_probe_args

FMT=()
case "$IMAGE" in
    *.bin) FMT=(--binary-format bin --base-address "${FLASH_ADDR:-0x0}") ;;
esac

hil_info "flashing $IMAGE -> $CHIP"
"$PROBE_RS" download "${PROBE_ARGS[@]}" "${FMT[@]}" "$IMAGE"
"$PROBE_RS" reset "${PROBE_ARGS[@]}"
