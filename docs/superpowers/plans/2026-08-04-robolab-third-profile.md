# r0b0lab Third Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an exact r0b0lab native-v11 production profile as a third switch target, prove its runtime identity, compare it fairly with the current 0731 profile, and restore the preferred profile.

**Architecture:** Keep the existing operational repository as the switch control plane. Generalize the switcher around profile-local lifecycle adapters and explicit state, while a clean pinned checkout of `r0b0tlab/DeepSeek-V4-Flash-DSpark-v026-SM121` owns the native-v11 launcher, runtime manifest, capability checks, and benchmark harness. Existing 0731 and DSpark profiles continue through thin adapters around the current Compose lifecycle.

**Tech Stack:** Bash, Python 3 standard library, Docker, SSH, vLLM OpenAI API, Prometheus metrics, GitHub/GHCR, pytest

## Global Constraints

- Preserve the currently working `0731` and `dspark` profiles and their cluster-local `.env.local` files.
- Add the exact r0b0lab production profile: 327,680 context, 16 sequences, 16,384 batched tokens, K=6, regular strict `FULL_DECODE_ONLY`, compilation mode `NONE`.
- Pin model revision `9e165c30e2704aec5d9d593cce3eebd58bbef1cb`.
- Pin image ID `sha256:2dfe24a303743722046c55bf2cf3ef9c9e6a40a008f73be16f9aa5c2ca38cf9b` and runtime manifest SHA-256 `f6777b31e8c8977361d629ca99c37a199d3b52b9abc134f1de624eb202f083a9`.
- Keep the r0b0lab checkout clean; do not vendor or modify its canonical runtime code.
- Never stop port 8888 while TransLLM or vLLM reports active requests.
- Stop panel-managed translation through `POST /api/runs/{run_id}/stop` with confirmation `stop {run_id}`; do not kill translation workers directly.
- A real switch writes active profile state only after target verification succeeds.
- A failed target switch automatically attempts rollback to the prior profile.
- Compare only C1/C2/C4/C6 because the current 0731 profile is configured for six sequences.
- Use the same prompts, tokenizer, output limits, and measurement definitions for both profiles.
- Restore `0731` after comparison unless r0b0lab is at least as reliable and offers a preferable translation quality/wall-clock trade-off.

---

### Task 1: Add a testable profile switch core

**Files:**
- Create: `scripts/profile_switch_lib.sh`
- Create: `tests/test_profile_switch.py`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: repository root, `profiles/<name>/profile.env`, optional `.env.local`, profile `start.sh`, `stop.sh`, `verify.sh`, and `${PROFILE_STATE_FILE}`.
- Produces: Bash functions `profile_names`, `profile_env`, `profile_value`, `active_profile`, `next_profile`, `validate_profile_layout`, `requests_in_flight`, `assert_endpoint_idle`, `activate_profile`, and `write_active_profile`.

- [ ] **Step 1: Permit tracked profile metadata while ignoring local state**

Add these rules to `.gitignore`:

```gitignore
!profiles/*/profile.env
.profile-state
bench-results/
```

The existing `profiles/*/.env.local` ignore rule remains unchanged.

- [ ] **Step 2: Write the failing profile discovery and toggle tests**

Create `tests/test_profile_switch.py` with a temporary repository fixture that copies `switch-deepseek-v4-flash.sh` and `scripts/profile_switch_lib.sh`, creates three fake profiles, and installs fake `curl`, `jq`, `ss`, `docker`, and `ssh` executables at the front of `PATH`.

The first tests must assert:

```python
def test_lists_profiles_in_declared_order(tmp_path):
    result = run_switch(tmp_path, "--profiles")
    assert result.stdout.split() == ["0731", "dspark", "robolab"]


def test_toggle_cycles_through_three_profiles(tmp_path):
    write_state(tmp_path, "0731")
    assert dry_run_target(tmp_path) == "dspark"
    write_state(tmp_path, "dspark")
    assert dry_run_target(tmp_path) == "robolab"
    write_state(tmp_path, "robolab")
    assert dry_run_target(tmp_path) == "0731"


def test_same_checkpoint_profiles_use_state_not_model_name(tmp_path):
    write_active_env(tmp_path, "deepseek-ai/DeepSeek-V4-Flash-0731")
    write_state(tmp_path, "robolab")
    result = run_switch(tmp_path, "--check")
    assert "active profile : robolab" in result.stdout
```

Use `SWITCH_REPO_ROOT`, `PROFILE_STATE_FILE`, `API_URL`, and `PATH` environment overrides so tests never touch the operational endpoint.

- [ ] **Step 3: Run the tests and verify RED**

Run:

```bash
python3 -m pytest tests/test_profile_switch.py -q
```

Expected: failures because `scripts/profile_switch_lib.sh`, `--profiles`, three-way toggle, and explicit state handling do not exist.

- [ ] **Step 4: Implement the minimal library**

Create `scripts/profile_switch_lib.sh` with:

```bash
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
  raw="${raw%\"}"; raw="${raw#\"}"
  printf '%s' "$raw"
}
profile_adapter() {
  local profile="$1" action="$2"
  printf '%s/%s/%s.sh\n' "$PROFILE_DIR" "$profile" "$action"
}
validate_profile_layout() {
  local profile="$1" action file
  file="$(profile_env "$profile")"
  [[ -f "$file" ]] || { printf 'missing profile env: %s\n' "$file" >&2; return 1; }
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
```

- [ ] **Step 5: Run the tests and verify GREEN**

Run:

```bash
python3 -m pytest tests/test_profile_switch.py -q
```

Expected: the profile discovery, ordering, toggle, and state tests pass.

- [ ] **Step 6: Commit**

```bash
git add .gitignore scripts/profile_switch_lib.sh tests/test_profile_switch.py
git commit -m "test: define three-profile switch contract"
```

### Task 2: Generalize the switcher and add rollback safety

**Files:**
- Modify: `switch-deepseek-v4-flash.sh`
- Modify: `scripts/profile_switch_lib.sh`
- Modify: `tests/test_profile_switch.py`
- Create: `profiles/0731/profile.env`
- Create: `profiles/0731/start.sh`
- Create: `profiles/0731/stop.sh`
- Create: `profiles/0731/verify.sh`
- Create: `profiles/dspark/profile.env`
- Create: `profiles/dspark/start.sh`
- Create: `profiles/dspark/stop.sh`
- Create: `profiles/dspark/verify.sh`

**Interfaces:**
- Consumes: Task 1 profile functions and existing global Compose lifecycle scripts.
- Produces: one adapter contract for every target and a switch transaction that validates, checks idle state, stops, starts, verifies, commits state, and rolls back on failure.

- [ ] **Step 1: Write failing adapter, idle-refusal, and rollback tests**

Add tests:

```python
def test_dry_run_validates_all_three_profile_adapters(tmp_path):
    result = run_switch(tmp_path, "--dry-run", "robolab")
    assert result.returncode == 0
    assert "DRY-RUN: no changes made" in result.stdout


def test_switch_refuses_when_vllm_has_running_requests(tmp_path):
    fake_metrics(tmp_path, running=2, waiting=0)
    result = run_switch(tmp_path, "robolab")
    assert result.returncode != 0
    assert "active requests" in result.stderr
    assert not lifecycle_log(tmp_path).exists()


def test_failed_target_start_rolls_back_without_changing_state(tmp_path):
    write_state(tmp_path, "0731")
    make_adapter(tmp_path, "robolab", start_exit=1)
    result = run_switch(tmp_path, "robolab")
    assert result.returncode != 0
    assert lifecycle_calls(tmp_path) == [
        "0731 stop", "robolab start", "robolab stop", "0731 start", "0731 verify"
    ]
    assert read_state(tmp_path) == "0731"


def test_state_changes_only_after_verify(tmp_path):
    write_state(tmp_path, "0731")
    make_adapter(tmp_path, "robolab", verify_exit=1)
    run_switch(tmp_path, "robolab")
    assert read_state(tmp_path) == "0731"
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
python3 -m pytest tests/test_profile_switch.py -q
```

Expected: failures because the current switcher directly copies env/compose files, has no adapter contract, does not check metrics, and has no rollback transaction.

- [ ] **Step 3: Add metadata and thin adapters for existing profiles**

Each existing `profile.env` contains:

```dotenv
PROFILE_NAME=0731
PROFILE_KIND=compose
EXPECTED_ROOT=deepseek-ai/DeepSeek-V4-Flash-0731
```

or:

```dotenv
PROFILE_NAME=dspark
PROFILE_KIND=compose
EXPECTED_ROOT=deepseek-ai/DeepSeek-V4-Flash-DSpark
```

`start.sh` must copy the selected profile's existing `.env.local` and `docker-compose.dspark.yml` to active files, then execute the current global start script. `stop.sh` executes the global stop script. `verify.sh` checks `/v1/models` root against `EXPECTED_ROOT` and sends the existing `Reply with OK` smoke request.

Adapters resolve the repository root through `PROFILE_REPO_ROOT`, defaulting to two directories above their own location.

- [ ] **Step 4: Implement request-idle and transactional switching**

`requests_in_flight` parses only:

```text
vllm:num_requests_running
vllm:num_requests_waiting
```

It sums matching live model series. `assert_endpoint_idle` succeeds when the endpoint is down or both totals are zero; otherwise it prints the counts and refuses to stop.

`activate_profile target prior` performs:

```text
validate target
assert endpoint idle
prior stop
try target start
try target verify
write state target
```

On target start or verify failure:

```text
target stop (best effort)
prior start
prior verify
leave prior state unchanged
return failure
```

- [ ] **Step 5: Rewrite command dispatch around the adapter contract**

Supported commands:

```text
--profiles
--check
--dry-run 0731|dspark|robolab
0731|dspark|robolab
toggle
```

Remove checkpoint-based `active_profile` inference. `--check` prints explicit state plus live served roots. `--dry-run` does not invoke request-idle checks or lifecycle adapters.

- [ ] **Step 6: Run focused tests and shell syntax checks**

Run:

```bash
python3 -m pytest tests/test_profile_switch.py -q
bash -n switch-deepseek-v4-flash.sh scripts/profile_switch_lib.sh profiles/{0731,dspark}/{start,stop,verify}.sh
```

Expected: all tests pass and all scripts parse.

- [ ] **Step 7: Commit**

```bash
git add switch-deepseek-v4-flash.sh scripts/profile_switch_lib.sh tests/test_profile_switch.py profiles/0731 profiles/dspark
git commit -m "feat: generalize DeepSeek profile switching"
```

### Task 3: Add the r0b0lab profile adapter

**Files:**
- Create: `profiles/robolab/profile.env`
- Create: `profiles/robolab/.env` (sanitized template)
- Create locally, ignored: `profiles/robolab/.env.local`
- Create: `profiles/robolab/start.sh`
- Create: `profiles/robolab/stop.sh`
- Create: `profiles/robolab/verify.sh`
- Modify: `tests/test_profile_switch.py`

**Interfaces:**
- Consumes: pinned r0b0lab checkout, its canonical production profile, launcher, runtime gate, manifest, exact GHCR image, and local HF cache snapshot.
- Produces: a fail-closed `robolab` lifecycle adapter compatible with Task 2.

- [ ] **Step 1: Write failing robolab prerequisite tests**

Add tests that construct fake checkout and image metadata, then assert `--dry-run robolab` rejects:

```python
def test_robolab_dry_run_rejects_missing_checkout(tmp_path): ...
def test_robolab_dry_run_rejects_dirty_checkout(tmp_path): ...
def test_robolab_dry_run_rejects_image_id_mismatch(tmp_path): ...
def test_robolab_dry_run_rejects_manifest_checksum_mismatch(tmp_path): ...
def test_robolab_dry_run_rejects_missing_model_revision_marker(tmp_path): ...
```

A final test supplies all pins and expects success without lifecycle calls.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
python3 -m pytest tests/test_profile_switch.py -q
```

Expected: failures because `profiles/robolab/` does not exist.

- [ ] **Step 3: Add tracked metadata and sanitized configuration**

`profiles/robolab/profile.env` pins:

```dotenv
PROFILE_NAME=robolab
PROFILE_KIND=robolab-native-v11
EXPECTED_ROOT=deepseek-ai/DeepSeek-V4-Flash-0731
EXPECTED_IMAGE_ID=sha256:2dfe24a303743722046c55bf2cf3ef9c9e6a40a008f73be16f9aa5c2ca38cf9b
EXPECTED_SOURCE_REVISION=cc6b2be9baa75d227f4f54d45bbbc98fb5b64094
EXPECTED_MODEL_REVISION=9e165c30e2704aec5d9d593cce3eebd58bbef1cb
EXPECTED_INTEGRATED_VLLM_COMMIT=fbad93432ebf60c8345397b3032fe03bf5d239cc
EXPECTED_VLLM_VERSION=0.26.0+dspark.sm121.3
EXPECTED_RUNTIME_AUDIT_MANIFEST_SHA256=f6777b31e8c8977361d629ca99c37a199d3b52b9abc134f1de624eb202f083a9
```

`profiles/robolab/.env` contains documentation-safe placeholders. The local `.env.local` supplies:

```dotenv
ROBOLAB_CHECKOUT=/home/binhdnguyen/ai/DeepSeek-V4-Flash-DSpark-v026-SM121
WORKER_HOST=10.200.0.2
MASTER_ADDR=10.200.0.1
MASTER_PORT=25000
DSPARK_MODEL_DIR=/home/binhdnguyen/ai/huggingface/hub/models--deepseek-ai--DeepSeek-V4-Flash-0731/snapshots/9e165c30e2704aec5d9d593cce3eebd58bbef1cb
DSPARK_HEAD_MODEL_DIR=/home/binhdnguyen/ai/huggingface/hub/models--deepseek-ai--DeepSeek-V4-Flash-0731/snapshots/9e165c30e2704aec5d9d593cce3eebd58bbef1cb
DSPARK_WORKER_MODEL_DIR=/home/binhdnguyen/ai/huggingface/hub/models--deepseek-ai--DeepSeek-V4-Flash-0731/snapshots/9e165c30e2704aec5d9d593cce3eebd58bbef1cb
HF_CACHE=/home/binhdnguyen/ai/huggingface
HEAD_ETH_IF=enp1s0f1np1
WORKER_ETH_IF=enp1s0f1np1
HEAD_IB_HCA=rocep1s0f1
WORKER_IB_HCA=rocep1s0f1
NCCL_IB_GID_INDEX=5
SERVED_MODEL_NAME=deepseek-v4-flash-dspark
```

- [ ] **Step 4: Implement `start.sh` using only canonical upstream runtime code**

The adapter:

1. sources `profile.env` and `.env.local`;
2. verifies the checkout is clean and contains the expected commit/history;
3. verifies the exact image ID on head and worker;
4. ensures `.r0b0tlab-model-revision` exists in the model snapshot on both nodes, writing only that marker after config/shard checks pass;
5. sources `${ROBOLAB_CHECKOUT}/profiles/dspark-r0b0tlab-production.env`;
6. exports all cluster-local overrides and immutable expected values;
7. executes `${ROBOLAB_CHECKOUT}/scripts/run-dspark-dual-gb10.sh`;
8. waits for `/v1/models` before returning.

Do not copy or edit the upstream launcher.

- [ ] **Step 5: Implement worker-first `stop.sh`**

The canonical runtime container is `dspark_vllm`. Stop worker first:

```bash
ssh "$WORKER_HOST" docker rm -f dspark_vllm || true
docker rm -f dspark_vllm || true
```

Then wait until port 8888 is free.

- [ ] **Step 6: Implement `verify.sh` through the canonical runtime gate**

Call:

```bash
python3 "$ROBOLAB_CHECKOUT/scripts/runtime_gate.py" \
  --container dspark_vllm \
  --worker-host "$WORKER_HOST" \
  --expected-image-id "$EXPECTED_IMAGE_ID" \
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
  --output "$ROBOLAB_VERIFY_OUTPUT"
```

Require JSON `status=PASS` and `errors=[]`.

- [ ] **Step 7: Run tests and syntax checks**

```bash
python3 -m pytest tests/test_profile_switch.py -q
bash -n profiles/robolab/{start,stop,verify}.sh
```

Expected: all tests pass.

- [ ] **Step 8: Commit tracked profile files**

```bash
git add profiles/robolab tests/test_profile_switch.py
git commit -m "feat: add r0b0lab native-v11 profile"
```

### Task 4: Provision the pinned r0b0lab runtime without disrupting 8888

**Files:**
- Create checkout: `/home/binhdnguyen/ai/DeepSeek-V4-Flash-DSpark-v026-SM121`
- Create locally: `profiles/robolab/.env.local`
- Create locally in both model snapshots: `.r0b0tlab-model-revision`

**Interfaces:**
- Consumes: public r0b0lab GitHub repository, GHCR image, existing 0731 weights, worker SSH.
- Produces: dry-run-complete prerequisites on both nodes while the current endpoint remains running.

- [ ] **Step 1: Clone and pin the runtime checkout**

```bash
git clone https://github.com/r0b0tlab/DeepSeek-V4-Flash-DSpark-v026-SM121.git \
  /home/binhdnguyen/ai/DeepSeek-V4-Flash-DSpark-v026-SM121
cd /home/binhdnguyen/ai/DeepSeek-V4-Flash-DSpark-v026-SM121
git checkout d8393134b49f7e92ffd64b9670b5d500fc6478cb
```

Expected: detached clean checkout containing the published native-v11 image documentation and canonical production profile.

- [ ] **Step 2: Create the cluster-local profile configuration**

Create ignored `profiles/robolab/.env.local` with the exact values defined in Task 3. Confirm no placeholder remains.

- [ ] **Step 3: Pull the immutable image on head and worker**

```bash
docker pull ghcr.io/r0b0tlab/deepseek-v4-flash-dspark-v026-sm121:v0.26.0-sm121-native-v11
ssh 10.200.0.2 docker pull ghcr.io/r0b0tlab/deepseek-v4-flash-dspark-v026-sm121:v0.26.0-sm121-native-v11
```

Expected: both nodes resolve to image ID `sha256:2dfe24a303743722046c55bf2cf3ef9c9e6a40a008f73be16f9aa5c2ca38cf9b`.

- [ ] **Step 4: Add and verify the local model revision markers**

Run the r0b0lab checkpoint verifier against the existing snapshot on each node. Because it requires the marker before validation, first validate `config.json`, the index total size, the complete 48-shard inventory, and non-empty resolved shard targets with an independent Python one-liner; then atomically create:

```text
.r0b0tlab-model-revision = 9e165c30e2704aec5d9d593cce3eebd58bbef1cb
```

Finally run `scripts/verify_model_checkpoint.py` on head and worker and require `DSPARK_MODEL_CHECKPOINT_VERIFY_PASS`.

- [ ] **Step 5: Run the non-destructive third-profile dry-run**

```bash
cd /home/binhdnguyen/ai/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark
./switch-deepseek-v4-flash.sh --dry-run robolab
```

Expected: all checkout, image, manifest, model, network, and adapter validations pass; port 8888 remains on the existing 0731 profile.

- [ ] **Step 6: Commit only documentation-safe changes if dry-run exposed corrections**

Never add `.env.local`, model markers, image data, or benchmark outputs.

### Task 5: Drain TransLLM and activate r0b0lab

**Files:**
- Runtime state only
- Evidence output: `/tmp/robolab-runtime-gate.json`

**Interfaces:**
- Consumes: panel API, idle endpoint, completed Task 4 prerequisites.
- Produces: verified r0b0lab runtime on port 8888 or automatic rollback to 0731.

- [ ] **Step 1: Discover active panel-managed runs**

Read the panel token from the Uvicorn environment or `.panel/panel_token`, then call:

```bash
curl -fsS -H "X-Panel-Token: $TOKEN" http://127.0.0.1:8460/api/runs
```

Select every run whose phase is not `DONE` or `FAILED`.

- [ ] **Step 2: Stop each active run through the panel API**

For each `$RID`:

```bash
curl -fsS -X POST \
  -H "X-Panel-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"force\":false,\"confirmation\":\"stop $RID\"}" \
  "http://127.0.0.1:8460/api/runs/$RID/stop"
```

Expected: `{"success":true}`. Wait until the panel shows each run in a terminal phase.

- [ ] **Step 3: Confirm the endpoint is idle**

Read `/metrics` until both request gauges are zero. Also confirm no unmanaged `transllm.cli translate` process remains. If an unmanaged process exists, stop and resolve it through its owning workflow before continuing; do not kill it blindly.

- [ ] **Step 4: Activate r0b0lab**

```bash
./switch-deepseek-v4-flash.sh robolab
```

Expected: existing 0731 stops, r0b0lab starts, its runtime gate passes, `.profile-state` becomes `robolab`, and `/v1/models` serves `deepseek-v4-flash-dspark` from the 0731 weights.

- [ ] **Step 5: Verify full runtime identity and smoke flow**

Check:

```bash
./switch-deepseek-v4-flash.sh --check
jq . /tmp/robolab-runtime-gate.json
curl -fsS http://127.0.0.1:8888/v1/models
```

Expected: exact image, package, integrated commit, manifest, graph configuration, K=6, production sizing, and semantic/tool/retrieval canaries pass with zero errors.

### Task 6: Benchmark r0b0lab and 0731 with matched systems inputs

**Files:**
- Create: `scripts/run_matched_profile_benchmark.py`
- Create: `tests/test_matched_profile_benchmark.py`
- Runtime outputs: `bench-results/profile-compare/<timestamp>/<profile>/systems.json`

**Interfaces:**
- Consumes: OpenAI-compatible endpoint and Prometheus metrics.
- Produces: schema-stable matched C1/C2/C4/C6 evidence for each profile and a combined comparison JSON.

- [ ] **Step 1: Write failing benchmark aggregation tests**

Test pure functions for:

```python
def test_steady_decode_excludes_first_token(): ...
def test_acceptance_uses_counter_deltas(): ...
def test_comparison_rejects_mismatched_prompt_or_max_tokens(): ...
def test_summary_reports_median_c1_and_each_concurrency(): ...
```

Use synthetic request rows and counter snapshots; no live endpoint in unit tests.

- [ ] **Step 2: Run tests and verify RED**

```bash
python3 -m pytest tests/test_matched_profile_benchmark.py -q
```

Expected: module missing.

- [ ] **Step 3: Implement the matched benchmark harness**

Use one fixed prompt, temperature 0, `ignore_eos=true`, streaming, one warm-up, five C1 repeats at 2,048 tokens, and two repeats each at C1/C2/C4/C6 with 512 tokens. Save request-level timings, server counter deltas, acceptance, errors, and profile identity supplied through `--profile`.

- [ ] **Step 4: Run unit tests and syntax checks**

```bash
python3 -m pytest tests/test_matched_profile_benchmark.py -q
python3 -m py_compile scripts/run_matched_profile_benchmark.py
```

Expected: pass.

- [ ] **Step 5: Run r0b0lab systems benchmark**

```bash
python3 scripts/run_matched_profile_benchmark.py \
  --profile robolab \
  --base-url http://127.0.0.1:8888 \
  --model deepseek-v4-flash-dspark \
  --output "$OUT/robolab/systems.json"
```

Expected: all fixed-token requests complete without infrastructure errors.

- [ ] **Step 6: Switch back to 0731 and run the identical benchmark**

Ensure idle, then:

```bash
./switch-deepseek-v4-flash.sh 0731
python3 scripts/run_matched_profile_benchmark.py \
  --profile 0731 \
  --base-url http://127.0.0.1:8888 \
  --model deepseek-v4-flash-dspark \
  --output "$OUT/0731/systems.json"
```

Expected: same prompt hash, token limits, concurrency set, and measurement definitions.

- [ ] **Step 7: Commit the benchmark harness**

```bash
git add scripts/run_matched_profile_benchmark.py tests/test_matched_profile_benchmark.py
git commit -m "feat: add matched DeepSeek profile benchmark"
```

### Task 7: Run the matched translation comparison

**Files:**
- Create: `scripts/run_translation_profile_benchmark.py`
- Create: `tests/test_translation_profile_benchmark.py`
- Runtime outputs: `bench-results/profile-compare/<timestamp>/<profile>/translation.json`

**Interfaces:**
- Consumes: eight fixed cached prompt JSON files from `prompt_cache_1807_1812`, the TransLLM finalizer/validator, and the active profile.
- Produces: request outputs, validator issues, completion tokens, wall time, acceptance, and blind-review bundles.

- [ ] **Step 1: Write failing cache-selection and result-validation tests**

Tests must prove:

```python
def test_selects_exact_same_eight_prompt_paths_in_sorted_order(): ...
def test_payload_enables_low_thinking_at_temperature_point_four(): ...
def test_validator_failures_are_counted_by_chunk(): ...
def test_blind_bundle_alternates_a_b_presentation_order(): ...
```

Freeze the eight filenames in a checked-in JSON fixture under `tests/fixtures/translation-profile-prompts.json`; do not select the first eight files dynamically.

- [ ] **Step 2: Run tests and verify RED**

```bash
python3 -m pytest tests/test_translation_profile_benchmark.py -q
```

Expected: module missing.

- [ ] **Step 3: Implement the translation replay harness**

For each frozen prompt:

- load `prompt.messages`;
- call `deepseek-v4-flash-dspark` with `temperature=0.4`, `top_p=1.0`, `max_tokens=12288`;
- explicitly send `chat_template_kwargs={"thinking": true, "reasoning_effort": "low"}`;
- persist raw response and usage;
- pass the content through the same TransLLM translation finalizer and validator used by production;
- record error codes including echo, empty output, low coverage, leftover CJK, and glossary misses;
- snapshot speculative counters around the full run.

Run at concurrency six. Generate alternating anonymized A/B files without assigning quality winners automatically.

- [ ] **Step 4: Run unit tests**

```bash
python3 -m pytest tests/test_translation_profile_benchmark.py -q
```

Expected: pass.

- [ ] **Step 5: Run translation benchmark on r0b0lab**

Switch to `robolab` only after the endpoint is idle, then run:

```bash
python3 scripts/run_translation_profile_benchmark.py \
  --profile robolab \
  --cache-dir /home/binhdnguyen/Documents/TransLLM/novels/xich_tam_tuan_thien/data/state/prompt_cache_1807_1812 \
  --selection tests/fixtures/translation-profile-prompts.json \
  --output "$OUT/robolab/translation.json"
```

- [ ] **Step 6: Run the identical translation benchmark on 0731**

Switch back after idle and run the same command with `--profile 0731`. Confirm prompt hashes and request settings match exactly.

- [ ] **Step 7: Commit the translation benchmark harness**

```bash
git add scripts/run_translation_profile_benchmark.py tests/test_translation_profile_benchmark.py tests/fixtures/translation-profile-prompts.json
git commit -m "feat: compare DeepSeek translation profiles"
```

### Task 8: Compare evidence and restore production state

**Files:**
- Create runtime report: `bench-results/profile-compare/<timestamp>/comparison.json`
- Create runtime report: `bench-results/profile-compare/<timestamp>/comparison.txt`
- Modify: `SWITCH-MODELS.md`

**Interfaces:**
- Consumes: matched systems and translation JSON for both profiles plus manual blind-review decisions.
- Produces: grounded recommendation, documented third-profile operations, and verified final serving state.

- [ ] **Step 1: Validate comparison inputs**

Reject the comparison if prompt hashes, fixed output lengths, temperatures, concurrency levels, or translation prompt selection differ. Report infrastructure failures separately from model/validator failures.

- [ ] **Step 2: Calculate matched deltas**

Report:

- median C1 steady decode delta;
- C1/C2/C4/C6 aggregate throughput deltas;
- draft acceptance deltas;
- request/preemption/error counts;
- translation wall-clock and completion-token deltas;
- validator failure counts and codes;
- blind quality wins/losses/ties.

Do not compare the live production workload rate against fixed-token benchmark rates.

- [ ] **Step 3: Select and restore the final profile**

Use this decision rule:

- restore `0731` if r0b0lab has any runtime-gate failure, infrastructure failure, worse validator reliability, or worse blind quality without a compelling wall-clock improvement;
- keep `robolab` only if runtime identity passes, validator reliability is no worse, blind quality is no worse, and wall-clock/throughput improvement is material.

Switch only after idle and verify the final profile with `--check`, served root, profile-specific verification, and one smoke request.

- [ ] **Step 4: Update operational documentation**

Update `SWITCH-MODELS.md` to document:

- three profiles and toggle order;
- explicit state file behavior;
- r0b0lab pinned checkout and image identity;
- dry-run and prerequisite checks;
- panel drain requirement;
- rollback behavior;
- profile-specific verification and benchmark commands.

Do not embed private tokens or generated benchmark payloads.

- [ ] **Step 5: Run final verification**

```bash
python3 -m pytest tests/test_profile_switch.py tests/test_matched_profile_benchmark.py tests/test_translation_profile_benchmark.py -q
bash -n switch-deepseek-v4-flash.sh scripts/profile_switch_lib.sh profiles/*/{start,stop,verify}.sh
./switch-deepseek-v4-flash.sh --check
curl -fsS http://127.0.0.1:8888/v1/models | jq -r '.data[] | .id + " root=" + .root'
```

Expected: tests and syntax checks pass; the chosen profile is live and verified; no active comparison process remains.

- [ ] **Step 6: Commit documentation and tracked changes**

```bash
git add SWITCH-MODELS.md
git commit -m "docs: document r0b0lab profile comparison"
```
