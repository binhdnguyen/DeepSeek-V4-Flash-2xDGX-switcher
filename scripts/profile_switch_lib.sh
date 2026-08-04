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

write_active_profile() {
  local temporary="$PROFILE_STATE_FILE.tmp.$$"
  printf '%s\n' "$1" >"$temporary"
  mv "$temporary" "$PROFILE_STATE_FILE"
}
