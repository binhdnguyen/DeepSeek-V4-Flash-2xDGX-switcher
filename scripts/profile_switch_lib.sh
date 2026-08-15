#!/usr/bin/env bash

PROFILE_STATE_FILE="${PROFILE_STATE_FILE:-$SCRIPT_DIR/.profile-state}"

# Profiles are DISCOVERED from $PROFILE_DIR, not hardcoded: any directory holding
# a profile.env is a profile. A hardcoded list silently breaks whenever the set
# of profiles on disk differs from the list in this file — e.g. a checkout that
# ships only a subset would still offer the missing ones from `--profiles` and
# then fail deep inside a switch. Discovery keeps the two in step by construction.
# Sorted for a stable toggle order.
profile_names() {
  local dir
  for dir in "$PROFILE_DIR"/*/; do
    [[ -f "$dir/profile.env" ]] || continue
    basename "$dir"
  done | LC_ALL=C sort
}

profile_exists() {
  local candidate="$1" name
  [[ -n "$candidate" ]] || return 1
  while IFS= read -r name; do
    [[ "$name" == "$candidate" ]] && return 0
  done < <(profile_names)
  return 1
}

# Mirror profiles/<p>/start.sh exactly: .env is the template, .env.local (gitignored,
# real cluster values) overrides it. Falling back to profile.env — which is metadata
# (PROFILE_NAME/PROFILE_KIND/EXPECTED_ROOT) and holds no WORKER_HOST/MASTER_ADDR —
# made a fresh clone resolve the worker address to the empty string AND made
# validate_target's placeholder guard pass vacuously, because it greps for keys that
# file never contains. Deployments with a .env.local are unaffected either way.
profile_env() {
  local profile="$1"
  if [[ -f "$PROFILE_DIR/$profile/.env.local" ]]; then
    printf '%s\n' "$PROFILE_DIR/$profile/.env.local"
  elif [[ -f "$PROFILE_DIR/$profile/.env" ]]; then
    printf '%s\n' "$PROFILE_DIR/$profile/.env"
  else
    printf '%s\n' "$PROFILE_DIR/$profile/profile.env"
  fi
}

active_profile() {
  local state
  state="$(cat "$PROFILE_STATE_FILE" 2>/dev/null || true)"
  if profile_exists "$state"; then
    printf '%s\n' "$state"
  else
    printf '%s\n' unknown
  fi
}

# Cycle to the next discovered profile; anything unrecognised restarts the cycle.
next_profile() {
  local current="$1" first="" prev="" name
  while IFS= read -r name; do
    [[ -z "$first" ]] && first="$name"
    if [[ "$prev" == "$current" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
    prev="$name"
  done < <(profile_names)
  printf '%s\n' "$first"
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
  local profile="$1" action file metadata
  file="$(profile_env "$profile")"
  metadata="$PROFILE_DIR/$profile/profile.env"
  [[ -f "$metadata" ]] || {
    printf 'missing profile metadata: %s\n' "$metadata" >&2
    return 1
  }
  [[ -f "$file" ]] || {
    printf 'missing profile env: %s\n' "$file" >&2
    return 1
  }
  [[ "$(sed -n 's/^PROFILE_NAME=//p' "$metadata" | sed -n '1p')" == "$profile" ]] || {
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
    return 1
  fi
  running="$(printf '%s\n' "$text" | awk '/^vllm:num_requests_running[{ ]/ {if ($NF !~ /^[0-9]+([.][0-9]+)?$/) exit 2; found=1; sum += $NF} END {if (!found) exit 1; print sum + 0}')" || return 1
  waiting="$(printf '%s\n' "$text" | awk '/^vllm:num_requests_waiting[{ ]/ {if ($NF !~ /^[0-9]+([.][0-9]+)?$/) exit 2; found=1; sum += $NF} END {if (!found) exit 1; print sum + 0}')" || return 1
  printf '%s %s\n' "$running" "$waiting"
}

endpoint_available() {
  curl -fsS --max-time 5 "${API_URL:-http://127.0.0.1:8888/v1/models}" >/dev/null 2>&1
}

assert_endpoint_idle() {
  local running waiting response
  if ! response="$(requests_in_flight)"; then
    if endpoint_available; then
      printf '%s\n' 'error: endpoint is live but metrics unavailable or invalid; refusing switch' >&2
      return 1
    fi
    return 0
  fi
  read -r running waiting <<<"$response"
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
