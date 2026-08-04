#!/usr/bin/env bash
set -euo pipefail
PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${PROFILE_ENV_FILE:-$PROFILE_DIR/.env}"
ssh "$WORKER_HOST" "docker rm -f dspark_vllm 2>/dev/null || true"
docker rm -f dspark_vllm 2>/dev/null || true
for _ in $(seq 1 30); do
  if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ':8888$'; then exit 0; fi
  sleep 1
done
echo 'error: port 8888 still listening after r0b0lab stop' >&2
exit 1
