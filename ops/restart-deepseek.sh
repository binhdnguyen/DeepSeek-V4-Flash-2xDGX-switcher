#!/usr/bin/env bash
# Clean restart of the 2-node DeepSeek-V4 cluster, pinned to DeepSeek-V4-Flash-0731.
# Run from the head node (head). Handles stale/hung containers on either node.
#
#   deepseek-restart          restart, refusing while requests are in flight
#   deepseek-restart --force  restart anyway (kills in-flight requests)
#
# Unlike the old version this pins the 0731 profile (copying its env + compose
# into place) instead of restarting whatever happened to be active, and it
# decides success from the API rather than from the start script's exit code —
# that probe reports "Startup failed" on healthy cold starts.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/deepseek-lib.sh"
[ -r "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
source "$LIB"

force=0
case "${1:-}" in
  -f|--force) force=1 ;;
  "") ;;
  *) echo "usage: $(basename "$0") [--force]" >&2; exit 2 ;;
esac

if (( ! force )); then
  if ! assert_endpoint_idle; then
    echo "Refusing to restart while requests are in flight. Drain first, or pass --force." >&2
    echo "TransLLM batch runs must be stopped through the panel, not killed." >&2
    exit 1
  fi
fi

ds_log "== restarting cluster (profile=$DS_PROFILE) =="
ds_clear_ranks
ds_bring_up
rc=$?
(( rc == 0 )) && ds_log "served: $(ds_served)"
exit "$rc"
