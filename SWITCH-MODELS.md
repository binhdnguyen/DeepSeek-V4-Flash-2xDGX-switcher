# Switch DeepSeek V4 Flash profiles on port 8888

One repository controls one shared two-node endpoint. Run everything from the
repository root.

## Profiles

| Profile | Runtime / checkpoint | Served model |
|---|---|---|
| `0731` | Anemll Compose runtime, `deepseek-ai/DeepSeek-V4-Flash-0731` | `deepseek-v4-flash-0731` |
| `dspark` | Anemll Compose runtime, original DSpark checkpoint | `deepseek-v4-flash-dspark` |

`0731` is the default lane. Toggle order is `0731 -> dspark -> 0731`.

Profiles are **discovered from the `profiles/` directory** — any directory
containing a `profile.env` is a profile — so adding or removing one needs no
edit to the switcher or its library.

Real cluster values live in ignored `profiles/<name>/.env.local` files. The
tracked `profiles/<name>/.env` templates ship placeholders and must stay
sanitized; the switcher refuses to deploy a profile whose env still contains
them.

## Commands

```bash
# List targets (discovered from profiles/)
./switch-deepseek-v4-flash.sh --profiles

# Read state, served identity, and request counters
./switch-deepseek-v4-flash.sh --check

# Validate all prerequisites without changing the endpoint
./switch-deepseek-v4-flash.sh --dry-run 0731

# Explicit switches
./switch-deepseek-v4-flash.sh 0731
./switch-deepseek-v4-flash.sh dspark

# Advance once in toggle order
./switch-deepseek-v4-flash.sh toggle
```

The active profile name is stored in `.profile-state`. This state changes only
after the target start and profile-specific verification both succeed. It is a
control-plane record, not proof that an endpoint is currently live; always use
`--check` and the profile verifier after an interrupted operation.

## Safety and rollback

Before a real switch:

1. Confirm no client has a non-final batch run in flight.
2. Confirm there is no unmanaged translation/benchmark process.
3. Require `vllm:num_requests_running=0` and `vllm:num_requests_waiting=0`.
4. Ensure each client is configured for the target's distinct served ID —
   `deepseek-v4-flash-0731` or `deepseek-v4-flash-dspark`. A switch does not
   rewrite external client settings automatically.

The switcher refuses a switch when live vLLM metrics report active requests, and
also refuses when the API is live but metrics are unavailable or malformed. An
endpoint that is fully down remains recoverable. If target start or verification
fails, it stops the failed target and attempts to start and verify the prior
profile. Do not edit `.profile-state` manually unless recovering from an
independently verified manual start.

> [!WARNING]
> `--check` reporting `port 8888: LISTEN` is **not** a health signal. On a 2-node
> deployment the head's rank-0 keeps answering `/v1/models` with the correct
> `root=` even when the worker is gone and no forward pass is possible. Only the
> profile verifier, which issues a real completion, distinguishes the two. See
> [docs/BOOT-AND-RECOVERY.md](docs/BOOT-AND-RECOVERY.md).

## Profile verification

```bash
./switch-deepseek-v4-flash.sh --check
profiles/0731/verify.sh       # when 0731 is active
profiles/dspark/verify.sh     # when dspark is active
```

Each verifier asserts the served `root=` matches the profile's `EXPECTED_ROOT`
**and** completes a real chat request. Verify by `root=`, never by served name:
a profile may serve aliases, so the name alone cannot tell two checkpoints apart.

## Matched benchmarks

Systems benchmark (same prompt and fixed output lengths for every profile):

```bash
OUT=/tmp/profile-compare-$(date -u +%Y%m%dT%H%M%SZ)
python3 scripts/run_matched_profile_benchmark.py \
  --profile 0731 \
  --base-url http://127.0.0.1:8888 \
  --model deepseek-v4-flash-0731 \
  --output "$OUT/0731/systems.json"
```

It runs one warm-up, five C1 repeats at 2,048 output tokens, and two rounds each
at C1/C2/C4/C6 with 512 tokens, temperature zero and `ignore_eos=true`.

Translation replay uses the frozen eight-file selection in
`tests/fixtures/translation-profile-prompts.json`:

```bash
python3 scripts/run_translation_profile_benchmark.py \
  --profile 0731 \
  --model deepseek-v4-flash-0731 \
  --cache-dir /path/to/your/prompt-cache-directory \
  --selection tests/fixtures/translation-profile-prompts.json \
  --output "$OUT/0731/translation.json"
```

Run identical commands after switching profiles, changing only `--profile`,
`--model` and the output directory. Reject a comparison if prompt hashes, token
limits, temperature, concurrency, or frozen file selection differ.

### Choosing `MTP_NUM_TOKENS`

`0731` ships `MTP_NUM_TOKENS=3`, not the upstream recipe's 5. At K=5 aggregate
throughput is a dead heat while draft acceptance falls 0.681 → 0.516 — more
draft compute discarded for no gain.

Speculative decoding is distribution-preserving, so **K cannot change token
counts at all**. Any token or wall-clock difference between K runs is sampling
noise, and acceptance rate is the low-variance measure. Isolate K with
fixed-token runs (`ignore_eos`); that methodology is right for K and for decode
rate, but it structurally cannot see token-count differences, which is what
dominates real batch wall-clock.

## Troubleshooting

- **"Startup failed" is often wrong.** The start script's readiness probe is too
  short for a cold start with TileLang/DeepGEMM/FlashInfer recompiles; it prints
  that message and exits nonzero while the engine is seconds from ready. Confirm
  against the API, not the exit code. Because profile files are copied *before*
  start, a "failed" switch has still changed the active config.
- A first cold boot can spend several minutes loading weights, warming TileLang
  kernels and autotuning FlashInfer before port 8888 listens. Weights alone take
  ~105 s.
- Hugging Face snapshots contain relative symlinks into their repository
  `blobs/` directory. Mount the whole model repository root, not just the
  snapshot, or `config.json` and shard symlinks break inside the container.
- Changing only `MTP_NUM_TOKENS` will **not** trigger a reload: the switcher
  exits "already active" when the target is loaded. Edit the active env and
  cycle the lane directly, then confirm K in the live process rather than in the
  env file.
