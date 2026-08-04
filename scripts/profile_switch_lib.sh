#!/usr/bin/env bash

PROFILE_ORDER=(0731 dspark robolab)
PROFILE_STATE_FILE="${PROFILE_STATE_FILE:-$SCRIPT_DIR/.profile-state}"

profile_names() { printf '%s\n' "${PROFILE_ORDER[@]}"; }

profile_env() {
  local profile="$1"
  if [[ -f "$PROFILE_DIR/$profile/.env.local" ]]; then
    printf '%s\n' "$PROFILE_DIR/$profile/.env.local"
  else
    printf '%s\n' "$PROFILE_DIR/$profile/profile.env"
  fi
}

active_profile() {
  local state
  state="$(cat "$PROFILE_STATE_FILE" 2>/dev/null || true)"
  case "$state" in
    0731|dspark|robolab) printf '%s\n' "$state" ;;
    *) printf '%s\n' unknown ;;
  esac
}

next_profile() {
  case "$1" in
    0731) printf '%s\n' dspark ;;
    dspark) printf '%s\n' robolab ;;
    robolab|unknown|none) printf '%s\n' 0731 ;;
  esac
}

profile_value() {
  local profile="$1" key="$2" file raw
  file="$(profile_env "$profile")"
  raw="$(sed -n "s/^${key}=//p" "$file" | sed -n '1p')"
  raw="${raw%\"}"
  raw="${raw#\"}"
  printf '%s' "$raw"
}

profile_adapter() {
  local profile="$1" action="$2"
  printf '%s/%s/%s.sh\n' "$PROFILE_DIR" "$profile" "$action"
}

validate_profile_layout() {
  local profile="$1" action file
  file="$(profile_env "$profile")"
  [[ -f "$file" ]] || {
    printf 'missing profile env: %s\n' "$file" >&2
    return 1
  }
  [[ "$(profile_value "$profile" PROFILE_NAME)" == "$profile" ]] || {
    printf 'PROFILE_NAME mismatch for %s\n' "$profile" >&2
    return 1
  }
  for action in start stop verify; do
    [[ -x "$(profile_adapter "$profile" "$action")" ]] || {
      printf 'missing executable adapter: %s\n' "$(profile_adapter "$profile" "$action")" >&2
      return 1
    }
  done
}
requests_in_flight() {
  local metrics="${METRICS_URL:-http://127.0.0.1:8888/metrics}" text running waiting
  text="$(curl -fsS --max-time 5 "$metrics" 2>/dev/null || true)"
  if [[ -z "$text" ]]; then
    printf '0 0\n'
    return
  fi
  running="$(printf '%s\n' "$text" | awk '/^vllm:num_requests_running[{ ]/ {sum += $NF} END {print sum + 0}')"
  waiting="$(printf '%s\n' "$text" | awk '/^vllm:num_requests_waiting[{ ]/ {sum += $NF} END {print sum + 0}')"
  printf '%s %s\n' "$running" "$waiting"
}

assert_endpoint_idle() {
  local running waiting
  read -r running waiting < <(requests_in_flight)
  if (( running > 0 || waiting > 0 )); then
    printf 'error: endpoint has active requests: running=%s waiting=%s\n' "$running" "$waiting" >&2
    return 1
  fi
}

run_profile_adapter() {
  local profile="$1" action="$2"
  PROFILE_REPO_ROOT="$SCRIPT_DIR" PROFILE_ENV_FILE="$(profile_env "$profile")" \
    "$(profile_adapter "$profile" "$action")"
}

activate_profile() {
  local target="$1" prior="$2"
  validate_profile_layout "$target"
  assert_endpoint_idle
  if [[ "$prior" != unknown && "$prior" != none ]]; then
    run_profile_adapter "$prior" stop
  fi
  if run_profile_adapter "$target" start && run_profile_adapter "$target" verify; then
    write_active_profile "$target"
    return 0
  fi
  printf 'error: activation of %s failed; rolling back to %s\n' "$target" "$prior" >&2
  run_profile_adapter "$target" stop || true
  if [[ "$prior" != unknown && "$prior" != none ]]; then
    run_profile_adapter "$prior" start
    run_profile_adapter "$prior" verify
  fi
  return 1
}


write_active_profile() {
  local state_dir temporary
  state_dir="$(dirname "$PROFILE_STATE_FILE")"
  mkdir -p "$state_dir"
  temporary="$(mktemp "$state_dir/.profile-state.tmp.XXXXXX")"
  trap 'rm -f "$temporary"' RETURN
  printf '%s\n' "$1" >"$temporary"
  mv "$temporary" "$PROFILE_STATE_FILE"
  trap - RETURN
}
