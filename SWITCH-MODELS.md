# Switch Models: DeepSeek-V4-Flash 0731 ↔ DSpark (port 8888)

**Date:** 2026-08-01 — re-created as a clean guide (was SWITCH-v026, model-set changed).
**Scope:** Alternate the shared 2x DGX-Spark vLLM endpoint on **0.0.0.0:8888** between
the two cached checkpoints. Everything below is verified against the live deployment.

## Profiles

Two canonical config pairs live under `profiles/` (seeded from the last-known-good
config + the `bak-before-0731` files).

> **Real cluster values live in `profiles/<name>/.env.local`.** The tracked
> `.env` is a placeholder template (`head-roce-ip`, `rocepXsYfZ`,
> `${HOME}/.cache/huggingface`) so this repo can stay public. The switcher
> prefers `.env.local` when present and refuses to deploy a profile whose
> addresses are still placeholders. On a fresh clone:
>
> ```bash
> cp profiles/0731/.env profiles/0731/.env.local   # then fill in real values
> cp profiles/dspark/.env profiles/dspark/.env.local
> ```

| Profile | Checkpoint (root) | Served names | MTP / flags |
|---|---|---|---|
| `0731` | `deepseek-ai/DeepSeek-V4-Flash-0731` (156G) | `deepseek-v4-flash-0731` **+** `deepseek-v4-flash-dspark` | MTP 5, `DEFAULT_THINKING=low`, `--enable-prompt-tokens-details`, encoding bootstrap |
| `dspark` | `deepseek-ai/DeepSeek-V4-Flash-DSpark` (161G) | `deepseek-v4-flash-dspark` | MTP 3, thinking off, `restart: unless-stopped` |

The `0731` profile's `docker-compose.dspark.yml` is **byte-identical to
MiaAI-Lab `upstream/main`**, and its `.env` follows the upstream recipe
(`MTP_NUM_TOKENS=5`, `DEFAULT_THINKING=low`, `VLLM_USE_BREAKABLE_CUDAGRAPH=0`).
Only cluster-specific values differ — addresses, cache paths, RoCE interfaces —
plus the additive `deepseek-v4-flash-dspark` alias in `SERVED_MODEL_NAME`.
`start-deepseek-v4-flash-dspark.sh` is byte-identical to upstream as well.

> **`MTP_NUM_TOKENS=5` is upstream's default, not this cluster's fastest.**
> `BENCHMARK-0731-vs-DSpark-20260801.md` measured K=3 at 42.35 tok/s vs K=5 at
> 39.48 (−11.7% at c1): accepted tokens per draft are ~flat (0.319×5 ≈ 0.530×3)
> while each K=5 verify step costs more. The profile keeps 5 for recipe parity;
> set `MTP_NUM_TOKENS=3` in `profiles/0731/.env` to restore the benchmarked
> optimum.

Both share the same runtime image `ghcr.io/anemll/dspark-vllm-gx10:0.1.1`
(same digest on head + worker), `--kv-cache-dtype nvfp4_ds_mla`, TP=2, 1M ctx,
`--moe-backend flashinfer_b12x`, DSpark speculative decoding.

> Note: **weights** are FP8-E4M3 (see `config.json` `"quant_method":"fp8"`).
> "NVFP4" in this repo = the *KV-cache* dtype (`nvfp4_ds_mla`), not the weights,
> and is unrelated to `nvidia/DeepSeek-V4-Flash-NVFP4`.

## Prerequisites (already in place)

- Both checkpoints cached on **head and worker**:
  `$HF_CACHE/hub/models--deepseek-ai--DeepSeek-V4-Flash-{0731,DSpark}`
- Runtime image present on both nodes.
- Passwordless SSH head → `$WORKER_HOST` for worker sync.
- Client **routing** is unaffected: both profiles serve the model name
  `deepseek-v4-flash-dspark`, so `~/.omp/agent/models.yml` / `config.yml`
  (`dspark/deepseek-v4-flash-dspark:high`) stay untouched.
- Client **output** is not identical across the two lanes: `0731` defaults to
  `DEFAULT_THINKING=low` (`{"thinking":true,"reasoning_effort":"low"}`, upstream's
  recipe default) so responses carry reasoning content, while `dspark` pins
  `{"thinking":false}`. Request-level overrides win on both. Pin
  `DEFAULT_THINKING=off` in `profiles/0731/.env` if you need the lanes to behave
  the same.

## Commands

Run from the repo root:

```bash
cd ~/ai/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark

# Current state + readiness (read-only)
./switch-deepseek-v4-flash.sh --check

# Dry-run a switch without touching anything
./switch-deepseek-v4-flash.sh --dry-run dspark

# Switch to the OLD DSpark weights
./switch-deepseek-v4-flash.sh dspark

# Switch to the NEW 0731 weights
./switch-deepseek-v4-flash.sh 0731

# Bare invocation toggles to whichever is NOT active
./switch-deepseek-v4-flash.sh
```

## What a switch does

1. `stop-deepseek-v4-flash-dspark.sh` — `docker compose down` head + worker
   (project `deepseek-v4-flash`).
2. Copy `profiles/<name>/.env` → `.env.dspark` and
   `profiles/<name>/docker-compose.dspark.yml` → `docker-compose.dspark.yml`.
3. `start-deepseek-v4-flash-dspark.sh` — syncs compose/env/proposer to worker,
   auto-resolves RoCEv2 GID indexes per node, boots both nodes, waits for the API
   and runs a `Reply with OK` smoke test.
4. Re-queries `/v1/models` to confirm the served identity.

A switch takes **~6 min** with a warm FlashInfer autotune cache (measured
2026-08-01: 367 s end-to-end, 0731 → dspark; weights load 216 s, engine init
81 s), up to **~10 min** cold when TileLang/DeepGEMM/FlashInfer must recompile.
The endpoint is down for the whole switch.

## Verify

```bash
./switch-deepseek-v4-flash.sh --check
# port 8888 : LISTEN
#   deepseek-v4-flash-dspark  root=deepseek-ai/DeepSeek-V4-Flash-DSpark   <- DSpark active
#   deepseek-v4-flash-dspark  root=deepseek-ai/DeepSeek-V4-Flash-0731     <- 0731 active

curl -s http://127.0.0.1:8888/v1/models | jq '.data[].root'
```

## Rollback / troubleshooting

- Failed start? The switch script surfaces head+worker container logs.
  Quick manual rollback:
  ```bash
  ./stop-deepseek-v4-flash-dspark.sh
  cp profiles/0731/.env .env.dspark && cp profiles/0731/docker-compose.dspark.yml docker-compose.dspark.yml
  ./start-deepseek-v4-flash-dspark.sh
  ```
- RoCEv2 GID resolution is automatic (`NCCL_IB_GID_AUTO=1`); only pin
  `NCCL_IB_GID_INDEX` / `WORKER_NCCL_IB_GID_INDEX` manually if auto fails.
- `-0731` needs its `encoding/encoding_dsv4.py`; the compose bootstrap copies it
  automatically. Do **not** remove the `DSPARK_ENCODING_FILE` handling in `profiles/0731`.
- Profiles are the source of truth for a switch. To capture a tuned live config as
  a new baseline, copy `.env.dspark` + `docker-compose.dspark.yml` back into the
  matching `profiles/<name>/` before switching away.

## Files

- `switch-deepseek-v4-flash.sh` — toggle/check/dry-run driver.
- `profiles/0731/{.env,docker-compose.dspark.yml}` — new-weights config.
- `profiles/dspark/{.env,docker-compose.dspark.yml}` — old-weights config.
- `profiles/*/.env.local` — real cluster values, gitignored, wins over `.env`.
- `.env.dspark` / `docker-compose.dspark.yml` — the **active** config (what the
  running endpoint used at launch).
