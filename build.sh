#!/usr/bin/env bash
# Single source of truth for the HIL build: every command that flashes runs this
# first, so a stale image can't reach the target. Point HIL_BUILD_CMD (dut.env)
# at whatever your project builds with — the toolkit only cares that $FIRMWARE
# and $FLASH_IMAGE exist afterwards.
#
#   ./build.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hil_load_env

[ -n "${HIL_BUILD_CMD:-}" ] || hil_die "set HIL_BUILD_CMD in dut.env (e.g. 'make -j\$(nproc)')"
hil_info "building: $HIL_BUILD_CMD"
( cd "$PROJECT_DIR" && eval "$HIL_BUILD_CMD" )
