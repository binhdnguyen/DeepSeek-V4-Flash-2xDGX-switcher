#!/usr/bin/env bash
set -euo pipefail
PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROFILE_DIR/profile.env"
source "${PROFILE_ENV_FILE:-$PROFILE_DIR/.env}"
output="${ROBOLAB_VERIFY_OUTPUT:-/tmp/robolab-runtime-gate.json}"
python3 "$ROBOLAB_CHECKOUT/scripts/runtime_gate.py" \
  --container dspark_vllm \
  --worker-host "$WORKER_HOST" \
  --expected-image-id "$EXPECTED_REGISTRY_DIGEST" \
  --expected-source-revision "$EXPECTED_SOURCE_REVISION" \
  --expected-model-revision "$EXPECTED_MODEL_REVISION" \
  --expected-integrated-vllm-commit "$EXPECTED_INTEGRATED_VLLM_COMMIT" \
  --expected-vllm-version "$EXPECTED_VLLM_VERSION" \
  --expected-profile production \
  --expected-cudagraph-implementation regular \
  --expected-cudagraph-mode FULL_DECODE_ONLY \
  --expected-compilation-config '{"mode":0,"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_implementation":"regular","cudagraph_strict":true}' \
  --expected-runtime-audit-manifest-sha256 "$EXPECTED_RUNTIME_AUDIT_MANIFEST_SHA256" \
  --expected-optimization-level 2 \
  --expected-performance-mode balanced \
  --base-url http://127.0.0.1:8888 \
  --model deepseek-v4-flash-dspark \
  --output "$output"
jq -e '.status == "PASS" and (.errors | length == 0)' "$output" >/dev/null
