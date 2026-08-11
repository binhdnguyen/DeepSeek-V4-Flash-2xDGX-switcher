#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.dspark.yml}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Copy .env.dspark.example to .env.dspark and edit it." >&2
  exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Missing $COMPOSE_FILE." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Mirror start-deepseek-v4-flash-dspark.sh's checkpoint resolution, or this
# script would report a different model than the one that actually gets served.
DSPARK_MODEL_OFFICIAL="${DSPARK_MODEL_OFFICIAL:-deepseek-ai/DeepSeek-V4-Flash-0731}"
DSPARK_MODEL_ABLITERATED="${DSPARK_MODEL_ABLITERATED:-drowzeys/keys-DeepSeekV4-Flash-GA-0731-Dspark-Abliterated-32-32}"
if [ "${ABLITERATED:-0}" = "1" ]; then
  DSPARK_MODEL="${DSPARK_MODEL_ABLITERATED}"
elif [ -z "${DSPARK_MODEL:-}" ]; then
  DSPARK_MODEL="${DSPARK_MODEL_OFFICIAL}"
fi
export DSPARK_MODEL

: "${WORKER_HOST:?WORKER_HOST must be set in $ENV_FILE}"
: "${MASTER_ADDR:?MASTER_ADDR must be set in $ENV_FILE}"
: "${MASTER_PORT:?MASTER_PORT must be set in $ENV_FILE}"
: "${DSPARK_VLLM_IMAGE:?DSPARK_VLLM_IMAGE must be set in $ENV_FILE}"

echo "DSpark config:"
echo "  worker: ${WORKER_HOST}"
echo "  master: ${MASTER_ADDR}:${MASTER_PORT}"
echo "  image: ${DSPARK_VLLM_IMAGE}"
echo "  checkpoint: ${DSPARK_MODEL} (ABLITERATED=${ABLITERATED:-0})"
echo "  revision: ${DSPARK_REVISION:-<cache default>}"
echo "  served model: ${SERVED_MODEL_NAME:-deepseek-v4-flash-dspark}"
echo "  max model len: ${MAX_MODEL_LEN:-1048576}"
echo "  max num seqs: ${MAX_NUM_SEQS:-6}"
echo "  max batched tokens: ${MAX_NUM_BATCHED_TOKENS:-8192}"
echo "  gpu memory utilization: ${GPU_MEMORY_UTILIZATION:-0.80}"
echo "  spec tokens (MTP_NUM_TOKENS): ${MTP_NUM_TOKENS:-3} with draft_sample_method=probabilistic"
echo "  cudagraph capture size: $(( ${MAX_NUM_SEQS:-6} * (${MTP_NUM_TOKENS:-3} + 1) )) (max_num_seqs * (mtp + 1))"
echo "  dspark slot clamp: ${DSPARK_SLOT_CLAMP:-1}"
echo "  sampling override: none (no --override-generation-config; --generation-config vllm only)"
echo "  WO projection: ${VLLM_USE_B12X_WO_PROJECTION:-1}"
echo "  host bind: ${VLLM_HOST:-127.0.0.1}"
echo
echo "Rendered vLLM command:"
env -u MASTER_PORT -u NODE_RANK -u HEADLESS -u WORKER_HOST -u MASTER_ADDR \
  COMPOSE_DISABLE_ENV_FILE=1 \
  DSPARK_MODEL="$DSPARK_MODEL" \
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config \
  | grep -E -- '--revision|--max-model-len|--max-num-seqs|--max-num-batched-tokens|--max-cudagraph-capture-size|--gpu-memory-utilization|--master-port|--kv-cache-dtype|--speculative-config|--async-scheduling|--enable-chunked-prefill|--generation-config|image:|VLLM_USE_B12X_WO_PROJECTION|VLLM_USE_FLASHINFER_SAMPLER|MTP_NUM_TOKENS'
