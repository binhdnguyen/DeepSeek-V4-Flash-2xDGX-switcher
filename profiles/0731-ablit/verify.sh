#!/usr/bin/env bash
set -euo pipefail
API_ORIGIN="${API_ORIGIN:-http://127.0.0.1:8888}"
EXPECTED_ROOT=drowzeys/keys-DeepSeekV4-Flash-GA-0731-Dspark-Abliterated-32-32
EXPECTED_ID=deepseek-v4-flash-0731-ablit
payload="$(curl -fsS --max-time 10 "$API_ORIGIN/v1/models")"
printf '%s' "$payload" | jq -e --arg root "$EXPECTED_ROOT" --arg id "$EXPECTED_ID" '
  (.data | any((.root == $root or (.root // "" | endswith($root))) and .id == $id))
  and (.data | all((.root // "") | contains("DSpark") | not))
' >/dev/null
curl -fsS --max-time 60 "$API_ORIGIN/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4-flash-0731-ablit","messages":[{"role":"user","content":"Reply with OK."}],"temperature":0,"max_tokens":32}' >/dev/null
