#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${SWITCH_REPO_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
PROFILE_DIR="${PROFILE_DIR:-$SCRIPT_DIR/profiles}"
API_URL="${API_URL:-http://127.0.0.1:8888/v1/models}"
METRICS_URL="${METRICS_URL:-http://127.0.0.1:8888/metrics}"

# shellcheck source=scripts/profile_switch_lib.sh
source "$SCRIPT_DIR/scripts/profile_switch_lib.sh"

usage() {
  local names
  names="$(profile_names | paste -sd'|' -)"
  cat <<EOF
Usage:
  switch-deepseek-v4-flash.sh --profiles
  switch-deepseek-v4-flash.sh --check
  switch-deepseek-v4-flash.sh --dry-run [${names}]
  switch-deepseek-v4-flash.sh [${names}|toggle]
EOF
}

# Valid targets come from what is on disk (see profile_names), so a checkout that
# ships a different set of profiles needs no edit here.
valid_profile() { profile_exists "$1"; }

probe() { curl -fsS --max-time 5 "$API_URL" 2>/dev/null || true; }

check_state() {
  local active
  active="$(active_profile)"
  printf 'active profile : %s\n' "$active"
  printf 'profiles       : %s\n' "$(profile_names | tr '\n' ' ')"
  printf '%s\n' '-- endpoints --'
  local response
  response="$(probe)"
  if [[ -n "$response" ]]; then
    printf '%s\n' 'port 8888      : LISTEN'
    printf '%s\n' 'served models  :'
    printf '%s' "$response" | jq -r '.data[]? | "  " + .id + "  root=" + (.root // "?")' 2>/dev/null || printf '%s\n' '  (API response invalid)'
  else
    printf '%s\n' 'port 8888      : free or API unavailable'
  fi
  local running waiting response
  if response="$(requests_in_flight)"; then
    read -r running waiting <<<"$response"
    printf 'requests       : running=%s waiting=%s\n' "$running" "$waiting"
  else
    printf '%s\n' 'requests       : unavailable'
  fi
}

validate_target() {
  local target="$1" env_file
  validate_profile_layout "$target"
  env_file="$(profile_env "$target")"
  if grep -qE '^(MASTER_ADDR|WORKER_HOST|ROBOLAB_CHECKOUT)=(head-roce-ip|worker-host-or-roce-ip|/path/to/)' "$env_file" 2>/dev/null; then
    printf 'error: %s contains placeholder cluster values\n' "$env_file" >&2
    return 1
  fi
  if [[ -x "$PROFILE_DIR/$target/validate.sh" ]]; then
    PROFILE_REPO_ROOT="$SCRIPT_DIR" PROFILE_ENV_FILE="$env_file" "$PROFILE_DIR/$target/validate.sh"
  fi
}

cmd="${1:-toggle}"
case "$cmd" in
  --profiles)
    profile_names
    ;;
  --check|-c)
    check_state
    ;;
  --help|-h)
    usage
    ;;
  --dry-run)
    active="$(active_profile)"
    target="${2:-$(next_profile "$active")}" 
    valid_profile "$target" || { printf 'error: unknown target %s\n' "$target" >&2; exit 2; }
    printf 'active profile : %s\n' "$active"
    printf 'target profile : %s\n' "$target"
    validate_target "$target"
    printf 'PLAN: %s stop -> %s start -> %s verify -> state=%s\n' "$active" "$target" "$target" "$target"
    printf '%s\n' 'DRY-RUN: no changes made.'
    ;;
  toggle)
    active="$(active_profile)"
    target="$(next_profile "$active")"
    validate_target "$target"
    activate_profile "$target" "$active"
    printf 'DONE: active profile = %s\n' "$target"
    ;;
  *)
    # Any name that matches a profile on disk is a switch target; everything
    # else is a usage error. Kept as the default branch so the accepted set is
    # defined solely by profile_names.
    if ! valid_profile "$cmd"; then
      printf 'error: unknown command %s\n' "$cmd" >&2
      usage >&2
      exit 2
    fi
    active="$(active_profile)"
    if [[ "$cmd" == "$active" ]]; then
      validate_target "$cmd"
      run_profile_adapter "$cmd" verify
      printf 'already active and verified: %s\n' "$cmd"
      exit 0
    fi
    validate_target "$cmd"
    activate_profile "$cmd" "$active"
    printf 'DONE: active profile = %s\n' "$cmd"
    ;;
esac
