#!/usr/bin/env bash
# Reset the target and let it run. Standalone probe op — needs no build.
#
#   ./reset.sh
#
# To stop the target at a known point instead, use ./gdb.sh break <fn>.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hil_load_env

hil_probe_require_free
hil_probe_args

hil_info "resetting $CHIP"
"$PROBE_RS" reset "${PROBE_ARGS[@]}"
