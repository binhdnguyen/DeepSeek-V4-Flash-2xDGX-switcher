#!/usr/bin/env bash
set -euo pipefail
#
# Switch the local DeepSeek-V4-Flash endpoint (port 8888, 2x DGX Spark)
# between the two cached checkpoints alternating on the same port:
#
#   0731   -> deepseek-ai/DeepSeek-V4-Flash-0731   (served as deepseek-v4-flash-0731 + deepseek-v4-flash-dspark)
#   dspark -> deepseek-ai/DeepSeek-V4-Flash-DSpark (served as deepseek-v4-flash-dspark)
#
# Profiles are stored under SCRIPT_DIR/profiles/<name>/ (seeded from the
# last-known-good config and the pre-0731 backup). Activating a profile:
#   stop current endpoint -> copy profile files onto .env.dspark /
#   docker-compose.dspark.yml -> run the repo start script (syncs the worker,
#   resolves RoCEv2 GID indexes, boots both nodes, waits for the API).
#
# Usage:
#   switch-deepseek-v4-flash.sh            # toggle to the non-active profile
#   switch-deepseek-v4-flash.sh 0731       # activate the 0731 profile
#   switch-deepseek-v4-flash.sh dspark     # activate the dspark profile
#   switch-deepseek-v4-flash.sh --check    # read-only: current state + readiness
#   switch-deepseek-v4-flash.sh --dry-run  # validate a target switch, touch nothing
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.dspark"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.dspark.yml"
PROFILE_DIR="$SCRIPT_DIR/profiles"
STOP_SH="$SCRIPT_DIR/stop-deepseek-v4-flash-dspark.sh"
START_SH="$SCRIPT_DIR/start-deepseek-v4-flash-dspark.sh"
API_URL="${API_URL:-http://127.0.0.1:8888/v1/models}"

usage() { sed -n '2,/^#$/p' "$0" | sed 's/^#\s*//'; }

active_profile() {
  if [ ! -f "$ENV_FILE" ]; then echo none; return; fi
  local m
  m="$(grep -E '^DSPARK_MODEL=' "$ENV_FILE" || true)"
  case "$m" in
    *0731*)  echo 0731 ;;
    *DSpark*) echo dspark ;;
    *) echo unknown ;;
  esac
}

# The tracked .env holds placeholders so this repo can stay public. Real
# cluster values belong in .env.local, which is gitignored and wins when present.
profile_env() {
  if [ -f "$PROFILE_DIR/$1/.env.local" ]; then
    echo "$PROFILE_DIR/$1/.env.local"
  else
    echo "$PROFILE_DIR/$1/.env"
  fi
}
profile_cfg() { echo "$PROFILE_DIR/$1/docker-compose.dspark.yml"; }

probe() { curl -fsS --max-time 5 "$API_URL" 2>/dev/null || true; }

env_value() {
  # $1 = key. Reads the active env file and expands ${HOME}/$HOME if present.
  local raw
  raw="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  raw="${raw%\"}"; raw="${raw#\"}"
  printf '%s' "${raw//\$\{HOME\}/$HOME}" | sed "s|\$HOME|$HOME|g"
}

get_worker_host() { env_value WORKER_HOST; }

list_checkpoint_dirs() {
  # $1 = ssh host ('' = local). Cache root comes from the active env file so no
  # machine-specific path is baked into this script.
  local ssh_t="$1" cache rem
  if [ -z "$ssh_t" ]; then
    cache="$(env_value HF_CACHE)"
  else
    cache="$(env_value WORKER_HF_CACHE)"
    [ -n "$cache" ] || cache="$(env_value HF_CACHE)"
  fi
  [ -n "$cache" ] || cache="$HOME/.cache/huggingface"
  rem="for m in DeepSeek-V4-Flash-0731 DeepSeek-V4-Flash-DSpark; do p=\"$cache/hub/models--deepseek-ai--\$m\"; if [ -d \"\$p\" ]; then echo \"\$p\"; fi; done"
  if [ -z "$ssh_t" ]; then
    bash -c "$rem"
  else
    ssh "$ssh_t" "$rem" 2>/dev/null || true
  fi
}

check_state() {
  local active
  active="$(active_profile)"
  echo "active profile : $active"
  echo "env file       : $ENV_FILE"
  echo "profiles       : $(ls "$PROFILE_DIR" 2>/dev/null | tr '\n' ' ')"
  echo "-- endpoints --"
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ':8888$'; then
    echo "port 8888      : LISTEN"
    echo "served models  :"
    probe | jq -r '.data[]? | "  " + .id + "  root=" + (.root // "?")' 2>/dev/null || echo "  (API not responding)"
  else
    echo "port 8888      : free (endpoint down)"
  fi
  echo "-- checkpoint presence --"
  for d in $(list_checkpoint_dirs ""); do echo "  head $d"; done
  local wh="$(get_worker_host)"
  if [ -n "$wh" ]; then
    for d in $(list_checkpoint_dirs "$wh"); do echo "  worker $d"; done
  fi
}

validate_target() {
  local t="$1"
  [ -f "$(profile_env "$t")" ] || { echo "error: missing $(profile_env "$t")" >&2; return 1; }
  [ -f "$(profile_cfg "$t")" ] || { echo "error: missing $(profile_cfg "$t")" >&2; return 1; }
  [ -x "$STOP_SH" ] || { echo "error: $STOP_SH not executable" >&2; return 1; }
  [ -x "$START_SH" ] || { echo "error: $START_SH not executable" >&2; return 1; }
  # Refuse to deploy the shipped placeholders -- they would take the endpoint
  # down and fail to bring it back on a cluster that never set .env.local.
  if grep -qE '^(MASTER_ADDR|WORKER_HOST)=(head-roce-ip|worker-host-or-roce-ip)$' \
      "$(profile_env "$t")" 2>/dev/null; then
    echo "error: $(profile_env "$t") still contains placeholder addresses." >&2
    echo "       Copy it to $PROFILE_DIR/$t/.env.local and fill in this cluster's" >&2
    echo "       addresses, interfaces and cache paths, then re-run." >&2
    return 1
  fi
}

switch_to() {
  local target="$1" active="$2"
  echo "SWITCH: $active -> $target"
  echo "  profile env   : $(profile_env "$target")"
  echo "  profile compose: $(profile_cfg "$target")"

  echo "[1/4] stopping current endpoint (head + worker)..."
  "$STOP_SH"

  echo "[2/4] installing $target profile onto active files..."
  cp "$(profile_env "$target")" "$ENV_FILE"
  cp "$(profile_cfg "$target")" "$COMPOSE_FILE"
  echo "  -> $ENV_FILE"
  echo "  -> $COMPOSE_FILE"

  echo "[3/4] starting $target endpoint (can take ~10 min on cold start)..."
  "$START_SH"

  echo "[4/4] verifying served identity..."
  probe | jq -r '.data[]? | .id + "  root=" + (.root // "?")' 2>/dev/null || echo "  (API not responding yet)"
  echo "DONE: active profile = $target"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
need_cmd curl
need_cmd jq
need_cmd ss

cmd="${1:-toggle}"
case "$cmd" in
  --check|-c)
    check_state
    exit 0
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  --dry-run)
    t="${2:-}"
    [ -n "$t" ] || { echo "error: --dry-run needs a target (0731|dspark)" >&2; usage >&2; exit 2; }
    case "$t" in 0731|dspark) ;; *) echo "error: unknown target $t (0731|dspark)" >&2; exit 2 ;; esac
    a="$(active_profile)"
    echo "active profile : $a"
    echo "target profile : $t"
    test "$t" = "$a" && { echo "already active; nothing to do (use --check for state)."; exit 0; }
    validate_target "$t" || exit 1
    echo "PLAN: stop-current -> cp $(profile_env "$t") -> $ENV_FILE"
    echo "                    -> cp $(profile_cfg "$t") -> $COMPOSE_FILE -> start"
    echo "DRY-RUN: no changes made."
    exit 0
    ;;
  0731|dspark)
    a="$(active_profile)"
    if [ "$cmd" = "$a" ]; then
      echo "already active: $cmd (use --check for state)."
      exit 0
    fi
    validate_target "$cmd" || exit 1
    switch_to "$cmd" "$a"
    ;;
  toggle|*)
    a="$(active_profile)"
    case "$a" in
      0731) t=dspark ;;
      dspark) t=0731 ;;
      none) t=0731 ;;
      unknown) echo "error: cannot detect active profile" >&2; exit 2 ;;
    esac
    validate_target "$t" || exit 1
    switch_to "$t" "$a"
    ;;
esac
