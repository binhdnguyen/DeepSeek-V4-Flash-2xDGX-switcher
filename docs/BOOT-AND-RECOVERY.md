# Boot and recovery for the 2-node cluster

DeepSeek-V4-Flash-0731 is the default lane here. This document covers bringing it
back automatically after a power event, and what the failure modes actually look
like on a 2-node TP=2 deployment.

Everything below is in `ops/`, and every number is measured on a 2× DGX Spark
(GB10) pair, not estimated.

```
ops/deepseek-lib.sh                    shared bring-up / health logic
ops/deepseek-boot-start.sh             what systemd runs at boot
ops/restart-deepseek.sh                manual clean restart
ops/reboot-deepseek.sh                 orchestrated both-node power cycle
ops/deepseek-v4-flash.service.example  systemd unit template
```

## The two rules that matter

**1. Never trust the start script's exit code.**
`start-deepseek-v4-flash-dspark.sh` has a readiness probe that is too short for a
cold start with TileLang / DeepGEMM / FlashInfer recompiles. It prints
`Startup failed`, dumps container logs and exits nonzero while the engine is
seconds away from serving. Health is therefore decided **only** by
`profiles/<p>/verify.sh`, polled — never by `$?`.

**2. `GET /v1/models` is not a health check.**
With the worker rebooted out from under it, the head's rank-0 container stays
`Up` and the API keeps answering `/v1/models` with the correct `root=`, despite
there being no rank-1 to run a forward pass. Any probe that only reads the model
list will call a dead cluster healthy. `verify.sh` issues a **real chat
completion** for this reason. This is not theoretical — it was observed directly
in the worker-reboot drill below.

## One code path for three incidents

| Incident | What survives | Why a naive restart hangs |
|---|---|---|
| Both nodes power-cut | nothing | — |
| Head only reboots | worker rank-1 | fresh rank-0 rendezvouses against a corpse |
| Worker only reboots | head rank-0 | mirror image |

`ds_bring_up()` opens **every** attempt by stopping both ranks, which collapses
all three into "clear, then start". The surviving rank is not idle — it is hung
at NCCL rendezvous and a fresh peer will wait on it forever.

It is also idempotent: if the cluster is already healthy it returns immediately
without touching the endpoint, so the boot unit is safe to `start` by hand.

## Sizing the worker wait

`DS_WORKER_WAIT` defaults to **2400s**. That is not padding:

- A measured worker reboot took **14m22s** from `reboot` to
  sshd + docker + persistenced ready.
- **~13 min of that was shutdown, not boot.** The node kept answering ping with
  sshd already stopped, then dropped off the network and reached sshd ~5s later.
  The vLLM container pinning GPU memory is the likely stall.
- An earlier 900s budget cleared this by **46 seconds**. Had it expired, the unit
  would have exited nonzero and left the cluster down after an ordinary reboot.

**Size the worker wait for shutdown, not boot.** And when a node pings but
refuses ssh after a reboot, that is very likely a slow shutdown in progress —
wait, do not power-cycle it.

## Drill results

Both were run against a live cluster.

**Head-only reboot** — dropped the head rank alone, leaving worker rank-1 up as
the corpse. Recovery tore down and rebuilt the worker rank, reloaded, verified
healthy in ~6 min. Weights load ~105s; total cold bring-up ~4–6 min.

**Worker-only reboot** — real `reboot` of the worker with the head rank left
running. Recovered on attempt 1/3. The opening `ds_healthy` check correctly
rejected the zombie endpoint (the real completion failed after ~60s) and
proceeded to rebuild, where a `/v1/models` probe would have returned "already
healthy" and walked away from a cluster serving zero tokens.

## Install

```bash
sed -e 's|__USER__|'"$USER"'|g' -e 's|__HOME__|'"$HOME"'|g' -e 's|__REPO__|'"$PWD"'|g' \
    ops/deepseek-v4-flash.service.example \
  | sudo tee /etc/systemd/system/deepseek-v4-flash.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now deepseek-v4-flash.service
```

Requires passwordless head→worker SSH that works **without** an ssh-agent
(systemd has none), and `sudo -n` on both nodes.

Tunables: `DS_PROFILE` (default `0731`), `DS_WORKER_WAIT`, `DS_LOCAL_WAIT`,
`DS_ATTEMPTS`, `DS_HEALTH_WAIT`, `DS_DEPLOY_DIR`, `DS_LOG_DIR`.

## Manual operations

```bash
ops/restart-deepseek.sh           # refuses while requests are in flight
ops/restart-deepseek.sh --force   # restart anyway
ops/reboot-deepseek.sh            # both-node cycle; --yes skips the prompt
```

`reboot-deepseek.sh` stops both ranks, reboots the worker and waits for it, then
verifies the boot unit is installed and enabled **before** rebooting the head —
so it cannot leave you with a head that comes back to no cluster. It aborts if
the worker does not return, rather than half-cycling the pair.

## A systemd footgun

A system unit's `Conflicts=` only resolves other **system** units. Pointing it at
a `systemctl --user` unit is silently inert: it names something that does not
exist at that scope and can never fire. If you need two lanes to exclude each
other across that boundary, disable one at boot and rely on real preflight
guards (port-in-use, free-memory checks) rather than a directive that looks like
protection but is not.
