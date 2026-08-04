#!/usr/bin/env bash
set -euo pipefail
PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROFILE_DIR/profile.env"
source "${PROFILE_ENV_FILE:-$PROFILE_DIR/.env}"
: "${ROBOLAB_CHECKOUT:?}"
: "${ROBOLAB_IMAGE:?}"
: "${WORKER_HOST:?}"
: "${DSPARK_HEAD_MODEL_DIR:?}"
: "${DSPARK_WORKER_MODEL_DIR:?}"
[[ -d "$ROBOLAB_CHECKOUT/.git" ]] || { echo "error: missing r0b0lab checkout: $ROBOLAB_CHECKOUT" >&2; exit 1; }
[[ -z "$(git -C "$ROBOLAB_CHECKOUT" status --porcelain)" ]] || { echo "error: r0b0lab checkout is dirty" >&2; exit 1; }
for path in profiles/dspark-r0b0tlab-production.env scripts/run-dspark-dual-gb10.sh scripts/runtime_gate.py scripts/verify_model_checkpoint.py recipe/runtime-manifest.vllm-sm121.3.json; do
  [[ -f "$ROBOLAB_CHECKOUT/$path" ]] || { echo "error: missing $ROBOLAB_CHECKOUT/$path" >&2; exit 1; }
done
[[ "$(sha256sum "$ROBOLAB_CHECKOUT/recipe/runtime-manifest.vllm-sm121.3.json" | cut -d' ' -f1)" == "$EXPECTED_RUNTIME_AUDIT_MANIFEST_SHA256" ]] || { echo "error: runtime manifest checksum mismatch" >&2; exit 1; }
local_config="$(docker buildx imagetools inspect "$ROBOLAB_IMAGE" --raw | jq -r '.config.digest')"
remote_config="$(ssh "$WORKER_HOST" "docker buildx imagetools inspect '$ROBOLAB_IMAGE' --raw" | jq -r '.config.digest')"
[[ "$local_config" == "$EXPECTED_IMAGE_ID" && "$remote_config" == "$EXPECTED_IMAGE_ID" ]] || { echo "error: native-v11 config digest mismatch: head=$local_config worker=$remote_config" >&2; exit 1; }
python3 "$ROBOLAB_CHECKOUT/scripts/verify_model_checkpoint.py" "$DSPARK_HEAD_MODEL_DIR" --expected-revision "$EXPECTED_MODEL_REVISION" >/dev/null
ssh "$WORKER_HOST" "python3 - '$DSPARK_WORKER_MODEL_DIR' --expected-revision '$EXPECTED_MODEL_REVISION'" < "$ROBOLAB_CHECKOUT/scripts/verify_model_checkpoint.py" >/dev/null
