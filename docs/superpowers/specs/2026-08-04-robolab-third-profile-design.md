# r0b0lab Third Profile Design

## Goal

Add a third switchable profile named `robolab` to the operational DeepSeek V4 Flash endpoint on port 8888. The profile must reproduce the frozen r0b0lab native-v11 production configuration, coexist with the current `0731` and `dspark` profiles, and support a matched comparison against `0731` without risking active TransLLM work.

## Scope

The third target reproduces the r0b0lab **production 327k** profile, not its max-context 1M profile:

- model weights: `deepseek-ai/DeepSeek-V4-Flash-0731`
- model revision: `9e165c30e2704aec5d9d593cce3eebd58bbef1cb`
- image tag: `ghcr.io/r0b0tlab/deepseek-v4-flash-dspark-v026-sm121:v0.26.0-sm121-native-v11`
- image ID: `sha256:2dfe24a303743722046c55bf2cf3ef9c9e6a40a008f73be16f9aa5c2ca38cf9b`
- package: `0.26.0+dspark.sm121.3`
- integrated vLLM commit: `fbad93432ebf60c8345397b3032fe03bf5d239cc`
- runtime manifest checksum: `f6777b31e8c8977361d629ca99c37a199d3b52b9abc134f1de624eb202f083a9`
- graph configuration: regular, strict, `FULL_DECODE_ONLY`, compilation mode `NONE`
- speculative decoding: DSpark K=6
- KV cache: `nvfp4_ds_mla`
- MoE backend: `flashinfer_b12x`
- `max_model_len=327680`
- `max_num_seqs=16`
- `max_num_batched_tokens=16384`
- `gpu_memory_utilization=0.835`
- `kv_cache_memory_bytes=15998753178`

The design does not copy or reinterpret the r0b0lab runtime into the existing Anemll Compose stack. Exact runtime behavior remains owned by a separate pinned r0b0lab checkout.

## Repository Strategy

Use a dedicated checkout at:

```text
/home/binhdnguyen/ai/DeepSeek-V4-Flash-DSpark-v026-SM121
```

Pin it to the repository revision that contains the native-v11 report and immutable runtime contract. Keep that checkout clean so its launcher can retain the upstream fail-closed clean-tree check.

The operational checkout remains the single control plane:

```text
DeepSeek-v4-Flash-DSpark-2x-DGX-Spark/
├── switch-deepseek-v4-flash.sh
├── profiles/0731/
├── profiles/dspark/
└── profiles/robolab/
```

`profiles/robolab/` contains cluster-specific adapters and configuration only. Canonical launcher code, runtime manifest, image verification, capability checks, and graph configuration remain in the pinned r0b0lab checkout.

## Profile Contract

Every switchable profile exposes these files:

- `.env.local` or `.env`: cluster and identity configuration
- `start.sh`: starts the selected profile and waits for its API identity
- `stop.sh`: stops that profile worker-first and then head

Existing `0731` and `dspark` behavior may continue through adapters that invoke the current global start and stop scripts. `robolab` adapters invoke the pinned checkout's native dual-GB10 launcher.

Profile metadata includes an explicit profile identity. Active profile detection must not depend only on `DSPARK_MODEL`, because `0731` and `robolab` serve the same checkpoint. A state file under the operational checkout records the profile selected by a successful switch. If the state file is absent or inconsistent, `--check` reports `unknown`; it must not guess `robolab` from model roots.

## Switcher Behavior

Accepted explicit targets:

```text
0731
dspark
robolab
```

Default toggle order:

```text
0731 → dspark → robolab → 0731
```

The switcher must support:

- `--check`
- `--dry-run <target>`
- explicit target activation
- deterministic three-way toggle

`--dry-run robolab` validates without touching the live endpoint:

1. profile metadata and adapters exist and are executable;
2. pinned checkout exists and is clean;
3. expected upstream files exist;
4. model directory and revision exist on head and worker;
5. exact runtime image is present on both nodes with matching image IDs;
6. runtime manifest checksum matches;
7. cluster addresses, interfaces, and paths are not placeholders;
8. port 8888 is not stopped or restarted.

A successful real switch writes the active-profile state only after API and runtime identity verification passes.

## Lifecycle and Rollback

A profile change can terminate in-flight requests. Before a real switch, the operator flow must:

1. inspect TransLLM panel runs and direct translation processes;
2. stop active panel-managed runs through the panel API using its required confirmation string;
3. wait until `vllm:num_requests_running=0` and `vllm:num_requests_waiting=0`;
4. capture the current profile as the rollback target;
5. validate the new profile;
6. stop worker before head;
7. start and verify the target;
8. restore the prior profile if target startup or identity verification fails.

The switcher itself must refuse a destructive switch when active model requests remain unless an explicit, separately named override is supplied. The normal comparison workflow does not use that override.

## r0b0lab Runtime Verification

The `robolab` adapter fails closed unless the live runtime matches all required pins:

- both served model IDs resolve to the 0731 model revision or the configured single r0b0lab served ID resolves to that revision;
- head and worker container image IDs equal the native-v11 image ID;
- vLLM package and integrated commit match;
- runtime manifest checksum matches;
- compilation configuration is mode 0, regular strict, `FULL_DECODE_ONLY`;
- speculative depth is K=6;
- production size parameters match the canonical profile;
- smoke completion succeeds through port 8888;
- runtime gate reports `PASS`, with no errors.

The profile may expose `deepseek-v4-flash-dspark` to preserve existing TransLLM clients. It must not claim the current Anemll alias layout if the canonical launcher exposes only one model ID.

## Matched Comparison

The comparison isolates runtime/profile behavior. Both profiles use the same 0731 checkpoint and client prompts.

### Systems benchmark

Run each profile after one warm-up:

- C1 decode with 2,048 generated tokens, five measured repeats;
- concurrency C1, C2, C4, and C6 using identical prompts and fixed output lengths;
- temperature 0 and `ignore_eos` for decode-rate isolation;
- identical tokenizer and benchmark client.

Record:

- client steady-state decode tokens per second;
- server-scoped decode tokens per second;
- aggregate generation tokens per second;
- TTFT;
- draft acceptance;
- preemptions;
- request and infrastructure failures;
- exact image, runtime, graph, K, and server arguments.

C6 is the highest matched concurrency because the existing `0731` profile has `max_num_seqs=6`. r0b0lab-only C16 results may be recorded separately but are not part of the direct comparison.

### Translation benchmark

Replay the existing eight cached TransLLM prompts against each profile with:

- temperature 0.4;
- thinking enabled at low/base effort;
- identical `max_tokens` and client validation;
- the same target-token boundaries;
- no name-based no-thinking override;
- alternating blind-review presentation order.

Record:

- validator failures;
- echo and leftover-CJK failures;
- completion-token count;
- wall-clock duration;
- aggregate generation rate;
- draft acceptance;
- blind quality winner.

The translation comparison is decision-bearing. A faster fixed-token systems result alone does not justify changing the production translation runtime.

## Final State

After both profiles are measured, restore `0731` unless the evidence shows `robolab` is at least as reliable and has a preferable translation quality and wall-clock trade-off. All three targets remain installed for future explicit switching.

## Validation

Before declaring completion:

1. switcher tests prove all three explicit targets, toggle order, state handling, dry-run validation, request-drain refusal, and rollback selection;
2. shell syntax checks pass for modified and new scripts;
3. `--dry-run robolab` succeeds without disturbing port 8888;
4. the real r0b0lab profile passes immutable identity checks and an API smoke completion;
5. r0b0lab and 0731 benchmarks use the same harness inputs;
6. the preferred profile is restored and verified by served root plus runtime identity.
