#!/usr/bin/env bash
# Shared bring-up / recovery helpers for the 2-node DeepSeek-V4 cluster.
#
# Sourced by deepseek-boot-start.sh, restart-deepseek.sh and reboot-deepseek.sh
# so all three agree on ONE definition of "the cluster is up".
#
# Design notes that are easy to get wrong:
#
#  * The pinned lane is 0731 (DS_PROFILE). dspark is retired — kept on disk only
#    so an old run can still be reproduced; nothing here should start it.
#
#  * start-deepseek-v4-flash-dspark.sh's readiness probe is TOO SHORT for a cold
#    start (TileLang / DeepGEMM / FlashInfer recompiles). It prints "Startup
#    failed" and exits nonzero while the engine is seconds from ready. So we
#    NEVER trust its exit code — health is decided only by ds_wait_healthy(),
#    which polls the profile's own verify.sh (root= match + a real completion).
#
#  * Recovery always begins by stopping BOTH ranks, even when we believe nothing
#    is running. That single step is what makes the three incident shapes
#    (both nodes down / head only / worker only) collapse into one code path —
#    see ds_bring_up().

DS_PROFILE="${DS_PROFILE:-0731}"

# profile_switch_lib.sh reads $SCRIPT_DIR (repo root), $PROFILE_DIR, $API_URL and
# $METRICS_URL from its caller. These scripts live in ~/ai/scripts, so SCRIPT_DIR
# must be set explicitly to the deploy checkout, not to our own directory.
SCRIPT_DIR="${DS_DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROFILE_DIR="$SCRIPT_DIR/profiles"
API_ORIGIN="${API_ORIGIN:-http://127.0.0.1:8888}"
API_URL="$API_ORIGIN/v1/models"
METRICS_URL="$API_ORIGIN/metrics"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/scripts/profile_switch_lib.sh"

DS_WORKER_HOST="$(profile_value "$DS_PROFILE" WORKER_HOST)"

ds_log() { printf '%s  %s\n' "$(date -Is)" "$*"; }

ds_ssh_worker() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$DS_WORKER_HOST" "$@"
}

# --- readiness gates -------------------------------------------------------

# The GPU driver and dockerd are both "active" before they are usable on a cold
# boot; pulling 155 GiB of weights into unified memory before then just OOMs.
ds_wait_local() {
  local deadline=$(( SECONDS + ${1:-300} ))
  ds_log "waiting for local nvidia + docker..."
  while (( SECONDS < deadline )); do
    if nvidia-smi -L >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      ds_log "  local nvidia + docker ready"
      return 0
    fi
    sleep 3
  done
  ds_log "  ERROR: local nvidia/docker not ready in time"
  return 1
}

# On a shared power-off the worker may boot slower than the head, or be powered
# on by hand minutes later — hence the generous default.
#
# 40 min, not 15. Measured 2026-08-06 (worker-only reboot drill): the worker node took
# 14m22s from `reboot` to sshd+docker+persistenced ready, and almost all of that
# was a HUNG SHUTDOWN — it kept answering ping with sshd already stopped for ~13
# min, then power-cycled and reached sshd in ~5 s. The vLLM container pinning GPU
# memory is the likely stall. A 900 s budget cleared that by 46 seconds; had it
# expired, boot-start would have exited 1 and left the cluster down after an
# ordinary reboot. Reboot-to-ready is dominated by shutdown, so size for it.
ds_wait_worker() {
  local deadline=$(( SECONDS + ${1:-2400} ))
  ds_log "waiting for worker $DS_WORKER_HOST (sshd + docker + persistenced)..."
  while (( SECONDS < deadline )); do
    if ds_ssh_worker 'docker info >/dev/null 2>&1 && test -S /run/nvidia-persistenced/socket' 2>/dev/null; then
      ds_log "  worker $DS_WORKER_HOST ready"
      return 0
    fi
    sleep 5
  done
  ds_log "  ERROR: worker $DS_WORKER_HOST did not come back in time"
  return 1
}

# --- health ----------------------------------------------------------------

# Identity check by root=, never by served name, and never by exit code of the
# start script. Delegates to profiles/<p>/verify.sh so there is one definition.
ds_healthy() {
  run_profile_adapter "$DS_PROFILE" verify >/dev/null 2>&1
}

ds_wait_healthy() {
  local deadline=$(( SECONDS + ${1:-900} ))
  ds_log "waiting for $DS_PROFILE to serve (root + live completion)..."
  while (( SECONDS < deadline )); do
    if ds_healthy; then
      ds_log "  healthy: $(ds_served)"
      return 0
    fi
    sleep 15
  done
  ds_log "  ERROR: endpoint did not become healthy in time"
  return 1
}

ds_served() {
  curl -fsS --max-time 5 "$API_URL" 2>/dev/null \
    | jq -r '.data[]? | .id + " root=" + (.root // "?")' 2>/dev/null \
    | paste -sd'; ' -
}

# --- recovery --------------------------------------------------------------

# Clear stale ranks on BOTH nodes. Safe when nothing is running (the stop script
# is `|| true` throughout), and REQUIRED when only one node was power-cycled:
# the surviving rank sits hung at NCCL rendezvous and will poison a fresh start.
ds_clear_ranks() {
  ds_log "clearing any stale ranks on head + worker..."
  run_profile_adapter "$DS_PROFILE" stop >/dev/null 2>&1 || true
}

# One code path for every incident shape. Returns 0 only on a verified endpoint.
ds_bring_up() {
  local attempts="${DS_ATTEMPTS:-3}" health_wait="${DS_HEALTH_WAIT:-900}" i

  if ds_healthy; then
    ds_log "already healthy, nothing to do: $(ds_served)"
    write_active_profile "$DS_PROFILE"
    return 0
  fi

  for (( i = 1; i <= attempts; i++ )); do
    ds_log "== bring-up attempt $i/$attempts (profile=$DS_PROFILE) =="
    ds_clear_ranks
    # rc deliberately ignored — see the "Startup failed is a lie" note up top.
    run_profile_adapter "$DS_PROFILE" start || ds_log "  start script exited nonzero (verifying anyway)"
    if ds_wait_healthy "$health_wait"; then
      write_active_profile "$DS_PROFILE"
      ds_log "== cluster UP (profile=$DS_PROFILE) =="
      return 0
    fi
    ds_log "  attempt $i failed"
  done

  ds_log "== cluster DID NOT COME UP after $attempts attempts =="
  ds_log "head logs:"
  ( cd "$SCRIPT_DIR" && ./logs-deepseek-v4-flash-dspark.sh 2>&1 | tail -60 ) || true
  return 1
}
