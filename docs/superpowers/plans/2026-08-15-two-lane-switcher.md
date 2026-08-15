# Two-lane Anemll switcher (DSpark translation + MiaAI 0731)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One operational checkout, two mutually exclusive recipes on port 8888 — a frozen DSpark think-off lane for translation, and a 0731 lane that tracks current MiaAI-Lab `main`.

**Architecture:** Rebase/replay the existing profile switcher onto `upstream/main`. Repo root is the MiaAI 0731 recipe. `profiles/dspark/` is a sealed think-off translation compose. `profiles/0731/` deploys official MiaAI 0731. `profiles/0731-ablit/` is the same MiaAI compose with `ABLITERATED=1` (optional). Clients stay on broker `:8879` / `local-auto` (8888 then 8880) and do not hardcode checkpoint ids.

**Tech Stack:** Anemll `ghcr.io/anemll/dspark-vllm-gx10:0.1.1` (digest-pinned on 0731), bash switcher, docker compose, two-node TP=2, TransLLM clients.

## Global Constraints

- Only one checkpoint resident. A switch is a full stop/start on both nodes (~6–10 min).
- Operational path only: `~/ai/DeepSeek-V4-Flash-2xDGX-switcher`.
- Served IDs stay distinct: `deepseek-v4-flash-dspark` vs `deepseek-v4-flash-0731`. 0731 must not alias the dspark name.
- DSpark thinking stays **off**. 0731 thinking stays MiaAI default (**max**). Do not force think-off on 0731 (source echo).
- TransLLM batch/preflight must be stopped via the panel before any switch.
- Cluster secrets stay in gitignored `profiles/<name>/.env.local`.
- Do not delete the tonyd2wild or eugr trees in this plan; just stop treating them as the 8888 operator.

---

## Target lanes

| | `dspark` (translation) | `0731` (MiaAI) |
|---|---|---|
| Weights | `deepseek-ai/DeepSeek-V4-Flash-DSpark` @ `62af8fffb2` | `deepseek-ai/DeepSeek-V4-Flash-0731` @ `9e165c30` |
| Served id | `deepseek-v4-flash-dspark` only | `deepseek-v4-flash-0731` only |
| Thinking | hardcoded `{"thinking":false}` | MiaAI `DEFAULT_THINKING=max` |
| K | 3 | 5 (MiaAI) |
| Context | 1,048,576 | 1,048,576 (MiaAI example) |
| Seqs / util | keep live translation values: **16 / 0.8** | MiaAI: **6 / 0.835 text** |
| Image | Anemll 0.1.1 (same tag, unpinned OK) | Anemll 0.1.1 **digest-pinned** |
| Compose | sealed copy in `profiles/dspark/` | repo-root MiaAI compose + hotfixes |
| TransLLM | `--model deepseek-v4-flash-dspark`, no thinking kwargs | `--model deepseek-v4-flash-0731`, think-max / budget per MiaAI README |

## What is gone from this operator

- 0731 official serving the `deepseek-v4-flash-dspark` alias
- Flipping `ABLITERATED` on the live official 0731 profile (use `0731-ablit` instead)
- Vision sidecar / MCP as something we run (`ENABLE_VL_SIDECAR=0`, do not install the plugin)
- Operating 8888 from tonyd2wild or eugr official (8880)
- Extra untracked bench/repro trees that are not needed for the two lanes
- Robolab / third-profile leftovers if any remain

## File map

- Keep: `switch-deepseek-v4-flash.sh`, `scripts/profile_switch_lib.sh`, `tests/test_profile_switch.py`, `SWITCH-MODELS.md`
- Replace root runtime from MiaAI `main`: `docker-compose.dspark.yml`, `start-deepseek-v4-flash-dspark.sh`, `stop-deepseek-v4-flash-dspark.sh`, `prepare-dspark-model-cache.sh`, `validate-dspark-config.sh`, `patches/*` (MiaAI set), `.env.dspark.example`
- Seal: `profiles/dspark/{.env,docker-compose.dspark.yml,start,stop,verify,profile.env}` from today’s working DSpark recipe
- Thin: `profiles/0731/start.sh` copies **root** compose + 0731 `.env.local` onto `.env.dspark`, then runs root start
- Cluster only: `profiles/dspark/.env.local`, `profiles/0731/.env.local` (gitignored)
- TransLLM: panel / `run_batch_parallel.sh` model name must match the active lane; no silent alias

---

### Task 1: Drain 8888 and snapshot cluster envs

**Files:** none committed. Read/write only gitignored env copies under `/tmp` or `~/ai/backups/`.

- [ ] **Step 1: Confirm what is on 8888**

```bash
curl -sS --max-time 5 http://127.0.0.1:8888/v1/models | python3 -c 'import sys,json; d=json.load(sys.stdin); [print(m.get("id"), m.get("root"), m.get("max_model_len")) for m in d.get("data",[])]'
```

Today this is expected to be tonyd2wild `Tony-DSv4F-0731-ablit`. Stop TransLLM runs via the panel first.

- [ ] **Step 2: Snapshot both profile locals and the two stack envs**

```bash
mkdir -p ~/ai/backups/two-lane-20260815
cp -a ~/ai/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark/profiles/dspark/.env.local \
      ~/ai/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark/profiles/0731/.env.local \
      ~/ai/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark/.env.dspark \
      ~/ai/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/.env.dspark \
      ~/ai/backups/two-lane-20260815/
```

- [ ] **Step 3: Unload every 8888/8880 operator**

```bash
~/ai/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark/stop-deepseek-v4-flash-dspark.sh || true
~/ai/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark/stop-deepseek-v4-flash-dspark.sh || true
~/ai/DeepSeek-V4-Flash-0731-official-2x-spark/scripts/stop.sh || true
ss -lptn 'sport = :8888 or sport = :8880'   # expect empty
```

---

### Task 2: Branch from current MiaAI `main` and port the switcher

**Files:**
- Modify: whole tree via git
- Keep working: `switch-deepseek-v4-flash.sh`, `scripts/profile_switch_lib.sh`, `tests/test_profile_switch.py`

- [ ] **Step 1: Fetch and branch**

```bash
cd ~/ai/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark
git fetch upstream
git switch -c lanes/dspark-and-mia-0731 upstream/main
```

Expected: `HEAD` = `f752cd0` (or newer tip). Working tree is MiaAI 0731 recipe.

- [ ] **Step 2: Restore switcher files from `feat/model-switcher` without taking that branch’s stale compose**

```bash
git checkout feat/model-switcher -- \
  switch-deepseek-v4-flash.sh \
  scripts/profile_switch_lib.sh \
  tests/test_profile_switch.py \
  SWITCH-MODELS.md
```

- [ ] **Step 3: Run switcher unit tests**

```bash
cd ~/ai/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark
python3 -m pytest tests/test_profile_switch.py -q
```

Expected: PASS (adapters are stubbed in the test fixture; does not need live GPUs).

- [ ] **Step 4: Commit**

```bash
git add switch-deepseek-v4-flash.sh scripts/profile_switch_lib.sh tests/test_profile_switch.py SWITCH-MODELS.md
git commit -m "feat: port two-profile switcher onto current MiaAI main"
```

---

### Task 3: Seal the DSpark translation profile

**Files:**
- Create/replace: `profiles/dspark/.env`, `profiles/dspark/docker-compose.dspark.yml`, `profiles/dspark/{start,stop,verify}.sh`, `profiles/dspark/profile.env`
- Create: `profiles/dspark/.env.local` from the backup (gitignored)

**Interfaces:**
- `profiles/dspark/start.sh` copies **only** `profiles/dspark/.env.local` → `.env.dspark` and `profiles/dspark/docker-compose.dspark.yml` → `docker-compose.dspark.yml`, then execs root start **or** a profile-local start if root start grows Mia-only hooks that break DSpark.
- Verify: `EXPECTED_ROOT=deepseek-ai/DeepSeek-V4-Flash-DSpark` and a completion.

- [ ] **Step 1: Copy today’s working DSpark compose+env from `feat/model-switcher`**

```bash
git checkout feat/model-switcher -- \
  profiles/dspark/.env \
  profiles/dspark/docker-compose.dspark.yml \
  profiles/dspark/profile.env \
  profiles/dspark/start.sh \
  profiles/dspark/stop.sh \
  profiles/dspark/verify.sh
```

- [ ] **Step 2: Lock translation knobs in `profiles/dspark/.env` (template) and `.env.local` (real)**

Template (`profiles/dspark/.env`) must stay placeholders for host/IPs. Set recipe knobs:

```
DSPARK_MODEL=deepseek-ai/DeepSeek-V4-Flash-DSpark
SERVED_MODEL_NAME=deepseek-v4-flash-dspark
MAX_MODEL_LEN=1048576
MAX_NUM_SEQS=16
GPU_MEMORY_UTILIZATION=0.8
MTP_NUM_TOKENS=3
```

Compose must keep `--default-chat-template-kwargs '{"thinking":false}'` and must **not** list `deepseek-v4-flash-0731` as a served alias.

`.env.local` = backup cluster IPs/HF_CACHE plus those same knobs.

- [ ] **Step 3: `verify.sh` checks root and think-off identity**

```bash
EXPECTED_ROOT=deepseek-ai/DeepSeek-V4-Flash-DSpark
# GET /v1/models: any(.root == $EXPECTED_ROOT) and .id == deepseek-v4-flash-dspark
# POST chat "Reply with OK." max_tokens=32 — HTTP 200, non-empty content
```

- [ ] **Step 4: Commit templates only (not `.env.local`)**

```bash
git add profiles/dspark
git commit -m "feat: seal dspark translation profile (think-off, K=3, 16 seqs)"
```

---

### Task 4: Make `0731` a thin MiaAI adapter

**Files:**
- Modify: `profiles/0731/start.sh`, `profiles/0731/stop.sh`, `profiles/0731/verify.sh`, `profiles/0731/profile.env`
- Replace: `profiles/0731/.env` from `.env.dspark.example` with 0731 names only
- Delete from 0731 env: `ABLITERATED`, `DSPARK_MODEL_ABLITERATED`, dual served-name comments
- Do not copy vision plugin; leave `ENABLE_VL_SIDECAR=0`

- [ ] **Step 1: `profiles/0731/start.sh` deploys root MiaAI files**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="${PROFILE_REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_SOURCE="$PROFILE_DIR/.env"
[[ -f "$PROFILE_DIR/.env.local" ]] && ENV_SOURCE="$PROFILE_DIR/.env.local"
cp "$ENV_SOURCE" "$ROOT/.env.dspark"
cp "$ROOT/docker-compose.dspark.yml" "$ROOT/docker-compose.dspark.yml"  # already root
# If profile ever needs a compose overlay, copy it here. Default: use MiaAI root compose.
exec "$ROOT/start-deepseek-v4-flash-dspark.sh"
```

`.env.local` is MiaAI example keys + this cluster’s IPs/HF_CACHE + official 0731:

```
DSPARK_MODEL=deepseek-ai/DeepSeek-V4-Flash-0731
DSPARK_REVISION=9e165c30e2704aec5d9d593cce3eebd58bbef1cb
SERVED_MODEL_NAME=deepseek-v4-flash-0731
DEFAULT_THINKING=max
MTP_NUM_TOKENS=5
MAX_NUM_SEQS=6
GPU_MEMORY_UTILIZATION=0.835
ABLITERATED=0
ENABLE_VL_SIDECAR=0
```

- [ ] **Step 2: `verify.sh` accepts only official 0731 root**

```
EXPECTED_ROOT=deepseek-ai/DeepSeek-V4-Flash-0731
# refuse if root contains keys- or DSpark
```

- [ ] **Step 3: Grep the 0731 path for the dspark alias and abliterated override**

```bash
rg -n 'deepseek-v4-flash-dspark|ABLITERATED=1|DSPARK_MODEL_ABLITERATED' \
  profiles/0731 docker-compose.dspark.yml start-deepseek-v4-flash-dspark.sh
```

Expected: no 0731 alias of the dspark name; `ABLITERATED` only as default `0` if MiaAI start script still reads the flag.

- [ ] **Step 4: Commit**

```bash
git add profiles/0731 docker-compose.dspark.yml start-deepseek-v4-flash-dspark.sh
git commit -m "feat: 0731 profile is MiaAI root recipe, no dspark alias, no ablit mode"
```

---

### Task 5: Docs + TransLLM contract

**Files:**
- Modify: `SWITCH-MODELS.md`
- Modify: TransLLM panel / batch scripts only if they hardcode the wrong model id

- [ ] **Step 1: Rewrite the profile table in `SWITCH-MODELS.md` to the two-lane table above**
- [ ] **Step 2: Point TransLLM production at `deepseek-v4-flash-dspark` until someone explicitly switches to 0731**
- [ ] **Step 3: Commit**

```bash
git add SWITCH-MODELS.md
git commit -m "docs: two-lane contract, distinct served ids"
```

---

### Task 6: Bring-up proof

- [ ] **Step 1: Dry-run both**

```bash
./switch-deepseek-v4-flash.sh --profiles    # only 0731 dspark
./switch-deepseek-v4-flash.sh --dry-run dspark
./switch-deepseek-v4-flash.sh --dry-run 0731
```

- [ ] **Step 2: Start DSpark (translation lane) and verify root + think-off**

```bash
./switch-deepseek-v4-flash.sh dspark
./switch-deepseek-v4-flash.sh --check
# expect: deepseek-v4-flash-dspark  root=...DeepSeek-V4-Flash-DSpark
```

One translation-shaped chat at think-off. Confirm it is not echoing Chinese.

- [ ] **Step 3: Switch to 0731 and verify Mia identity**

```bash
./switch-deepseek-v4-flash.sh 0731
# expect: deepseek-v4-flash-0731  root=...DeepSeek-V4-Flash-0731
# expect: max_model_len from MiaAI recipe, K=5 in process cmdline
```

- [ ] **Step 4: Switch back to dspark (the production translation default)**

Do not leave 0731 loaded unless asked.

---

## Later (not this plan)

- Periodic `git fetch upstream && git merge upstream/main` on `lanes/dspark-and-mia-0731`. DSpark profile must not be overwritten; review compose conflicts on root files only.
- Keys abliterated as a third profile only if requested again.
- Deleting `~/ai/DeepSeek-V4-Flash-0731-official-2x-spark` or the tonyd2wild tree — disk cleanup, separate decision.
- Publishing the two-lane branch to `-publish`.
