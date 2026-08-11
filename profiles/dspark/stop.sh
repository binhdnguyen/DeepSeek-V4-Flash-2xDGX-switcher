#!/usr/bin/env bash
set -euo pipefail
ROOT="${PROFILE_REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
exec "$ROOT/stop-deepseek-v4-flash-dspark.sh"
