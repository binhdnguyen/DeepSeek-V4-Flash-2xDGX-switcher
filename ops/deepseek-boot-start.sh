#!/usr/bin/env bash
# Boot-start for the 2-node DeepSeek-V4 cluster — DeepSeek-V4-Flash-0731 is the
# default lane on this cluster and comes up on every boot of the head.
#
# History: this used to be a one-shot armed by reboot-deepseek.sh that disabled
# its own unit on the way out. It is now PERSISTENT (deepseek-v4-flash.service,
# enabled), so the cluster returns by itself after any power event — nothing has
# to be armed in advance, which is exactly what an unplanned outage denies you.
#
# Incident shapes this must survive, and why one code path covers all three:
#
#   both nodes power-cycled  — nothing is running anywhere. We wait for the
#                              worker (it may boot slower, or be switched on by
#                              hand later) and start clean.
#   only the head rebooted   — the worker's rank-1 container is still up and
#                              hung at NCCL rendezvous. A fresh head rank would
#                              rendezvous against that corpse and hang forever.
#   only the worker rebooted — mirror image: the head's rank-0 is the corpse.
#
# ds_bring_up() opens every attempt with a both-node stop, so all three reduce
# to "clear, then start". Health is judged by the API (root= + a real
# completion), never by the start script's exit code.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/deepseek-lib.sh"
[ -r "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
source "$LIB"

LOG_DIR="${DS_LOG_DIR:-$SCRIPT_DIR/logs}"
LOG="$LOG_DIR/boot-deepseek-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

{
  ds_log "== deepseek boot-start (profile=$DS_PROFILE, worker=$DS_WORKER_HOST) =="

  ds_wait_local  "${DS_LOCAL_WAIT:-300}"   || exit 1
  ds_wait_worker "${DS_WORKER_WAIT:-2400}" || exit 1

  ds_bring_up
  rc=$?
  ds_log "== boot-start finished rc=$rc =="
  exit "$rc"
} 2>&1 | tee -a "$LOG"

exit "${PIPESTATUS[0]}"
