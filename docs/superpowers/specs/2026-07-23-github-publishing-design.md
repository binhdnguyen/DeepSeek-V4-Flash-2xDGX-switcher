# DeepSeek Configuration GitHub Publishing Design

## Goal

Publish the currently running two-node DeepSeek V4 Flash DSpark configuration as a reusable public repository at `binhdnguyen/DeepSeek-V4-Flash-DSpark-2x-DGX-Spark`.

## Repository Strategy

- Preserve the existing MiaAI-Lab commit history and attribution.
- Create a local `main` branch from the current checked-out upstream commit.
- Retain `https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark.git` as the `upstream` remote.
- Create the new public GitHub repository and use it as `origin`.
- Include the current `restart: unless-stopped` Compose customization.

## Published Content

Publish the existing runtime recipes, scripts, patches, license, credits, README, sanitized `.env.dspark.example`, and useful inherited benchmark source code and checkpoint Markdown that document upstream behavior and provenance. Preserve those useful benchmark materials when they are already part of upstream history.

Do not publish generated benchmark results or output directories, local runtime captures, the active `.env.dspark`, model weights, caches, logs, credentials, keys, tokens, or machine-specific secrets.

## Validation

Before pushing:

1. Review the full staged diff and repository status.
2. Scan tracked content for credentials and private configuration.
3. Validate the Docker Compose configuration using the sanitized example.
4. Run shell syntax checks on tracked shell scripts.
5. Confirm `.env.dspark` remains ignored and untracked.

After pushing, verify the public repository URL, default branch, and visible files.
