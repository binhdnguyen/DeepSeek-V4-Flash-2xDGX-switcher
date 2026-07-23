# DeepSeek Configuration GitHub Publishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the current two-node DeepSeek V4 Flash DSpark configuration as the public standalone repository `binhdnguyen/DeepSeek-V4-Flash-DSpark-2x-DGX-Spark`.

**Architecture:** Preserve the existing MiaAI-Lab history, create a local `main` branch, retain the original repository as `upstream`, and publish the customized branch to a new `origin`. Only tracked reusable configuration is published; active environment files, credentials, caches, logs, and model data remain excluded.

**Tech Stack:** Git, GitHub CLI, Docker Compose, Bash, vLLM

## Global Constraints

- Preserve existing MiaAI-Lab commit history and attribution.
- Publish as a public standalone repository, not a GitHub fork.
- Repository name must be `DeepSeek-V4-Flash-DSpark-2x-DGX-Spark`.
- Never add `.env.dspark`, keys, tokens, logs, caches, benchmarks, or model weights.
- Preserve the existing `restart: unless-stopped` customization.
- Do not stop or restart the currently running DeepSeek service.

---

### Task 1: Establish the standalone branch and remotes

**Files:**
- No file changes

**Interfaces:**
- Consumes: detached `HEAD` containing the committed design specification
- Produces: local `main` branch, `upstream` remote pointing to MiaAI-Lab, and no new `origin` until GitHub repository creation

- [ ] **Step 1: Confirm GitHub authentication**

Run:

```bash
gh auth status
```

Expected: authenticated to `github.com` as `binhdnguyen` with repository creation and push access.

- [ ] **Step 2: Create the local main branch**

Run:

```bash
git switch -c main
```

Expected: `Switched to a new branch 'main'`; the existing modified `docker-compose.dspark.yml` remains present.

- [ ] **Step 3: Rename the existing upstream remote**

Run:

```bash
git remote rename origin upstream
git remote -v
```

Expected: both fetch and push URLs for `upstream` are `https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark.git`.

### Task 2: Validate and commit the reusable runtime customization

**Files:**
- Modify: `docker-compose.dspark.yml`
- Existing: `.env.dspark.example`
- Existing: `.gitignore`

**Interfaces:**
- Consumes: current Compose configuration and sanitized example environment
- Produces: reviewed commit containing `restart: unless-stopped`

- [ ] **Step 1: Verify sensitive local files are excluded**

Run:

```bash
git check-ignore -v .env.dspark
git ls-files '.env*' '*.pem' '*.key' '*.log'
```

Expected: `.env.dspark` matches `.gitignore`; only `.env.dspark.example` is tracked among environment files, with no tracked keys or logs.

- [ ] **Step 2: Scan tracked content for secrets**

Run:

```bash
git grep -nIE '(ghp_|github_pat_|hf_[A-Za-z0-9]{20,}|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|api[_-]?key[[:space:]]*[:=][[:space:]]*[^$<{])' -- . ':!docs/superpowers'
```

Expected: no matches containing live credentials. Any match must be inspected before continuing.

- [ ] **Step 3: Validate the Compose configuration**

Run:

```bash
COMPOSE_DISABLE_ENV_FILE=1 \
NODE_RANK=0 \
HEADLESS= \
WORKER_HOST=worker.example \
MASTER_ADDR=192.0.2.10 \
MASTER_PORT=25000 \
NCCL_IB_HCA=rocep1s0f1 \
NCCL_SOCKET_IFNAME=enp1s0f1np1 \
docker compose --env-file .env.dspark.example -f docker-compose.dspark.yml config --quiet
```

Expected: exit code `0`.

- [ ] **Step 4: Validate tracked shell scripts**

Run:

```bash
git ls-files '*.sh' -z | xargs -0 -n1 bash -n
```

Expected: exit code `0` with no syntax errors.

- [ ] **Step 5: Review and stage the customization**

Run:

```bash
git diff --check
git diff -- docker-compose.dspark.yml
git add docker-compose.dspark.yml
git diff --cached
git status
```

Expected: staged diff contains only `restart: unless-stopped`; the plan document may remain uncommitted until Task 3.

- [ ] **Step 6: Commit the runtime customization**

Run:

```bash
git commit -m "fix: restart DeepSeek service unless stopped

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

Expected: one commit containing only `docker-compose.dspark.yml`.

### Task 3: Publish and verify the GitHub repository

**Files:**
- Create: `docs/superpowers/plans/2026-07-23-github-publishing.md`

**Interfaces:**
- Consumes: validated local `main` branch and authenticated GitHub CLI
- Produces: public GitHub repository and configured `origin`

- [ ] **Step 1: Commit the implementation plan**

Run:

```bash
git add docs/superpowers/plans/2026-07-23-github-publishing.md
git diff --cached
git status
git commit -m "docs: add GitHub publishing implementation plan

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

Expected: one documentation commit with no sensitive content.

- [ ] **Step 2: Create the public GitHub repository**

Run:

```bash
gh repo create binhdnguyen/DeepSeek-V4-Flash-DSpark-2x-DGX-Spark \
  --public \
  --description "Two-node DeepSeek V4 Flash DSpark vLLM recipe for NVIDIA DGX Spark with 1M context, NVFP4 DS-MLA KV cache, speculative decoding, and prefix caching"
```

Expected: GitHub reports the new repository URL.

- [ ] **Step 3: Configure origin and review the push**

Run:

```bash
git remote add origin https://github.com/binhdnguyen/DeepSeek-V4-Flash-DSpark-2x-DGX-Spark.git
git remote -v
git status
git log --oneline --decorate -5
```

Expected: `origin` points to `binhdnguyen`; `upstream` points to MiaAI-Lab; working tree is clean.

- [ ] **Step 4: Push main**

Run:

```bash
git push -u origin main
```

Expected: `main` is created on GitHub and configured as the tracking branch.

- [ ] **Step 5: Verify the published repository**

Run:

```bash
gh repo view binhdnguyen/DeepSeek-V4-Flash-DSpark-2x-DGX-Spark \
  --json url,visibility,defaultBranchRef,description
gh api repos/binhdnguyen/DeepSeek-V4-Flash-DSpark-2x-DGX-Spark/contents/.env.dspark
```

Expected: repository is `PUBLIC`, default branch is `main`, and the `.env.dspark` content request returns HTTP `404`.
