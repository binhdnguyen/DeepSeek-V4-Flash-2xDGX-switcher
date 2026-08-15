#!/usr/bin/env bash
set -euo pipefail
ROOT="${PROFILE_REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_SOURCE="$PROFILE_DIR/.env"
[[ -f "$PROFILE_DIR/.env.local" ]] && ENV_SOURCE="$PROFILE_DIR/.env.local"
cp "$ENV_SOURCE" "$ROOT/.env.dspark"
# Restore MiaAI root compose — dspark start overwrites the working-tree file.
git -C "$ROOT" checkout HEAD -- docker-compose.dspark.yml
exec "$ROOT/start-deepseek-v4-flash-dspark.sh"
