#!/usr/bin/env bash
set -euo pipefail
API_ORIGIN="${API_ORIGIN:-http://127.0.0.1:8888}"
EXPECTED_ROOT=deepseek-ai/DeepSeek-V4-Flash-DSpark
EXPECTED_ID=deepseek-v4-flash-dspark
payload="$(curl -fsS --max-time 10 "$API_ORIGIN/v1/models")"
printf '%s' "$payload" | jq -e --arg root "$EXPECTED_ROOT" --arg id "$EXPECTED_ID" \
  '.data | any(.root == $root and .id == $id)' >/dev/null
curl -fsS --max-time 60 "$API_ORIGIN/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4-flash-dspark","messages":[{"role":"user","content":"Reply with OK."}],"temperature":0,"max_tokens":32}' >/dev/null
