#!/usr/bin/env bash
set -euo pipefail

MODEL_NAME="${MODEL_NAME:-qwen3:4b}"
BASE_URL="${OPENAI_BASE_URL:-http://host.docker.internal:11434/v1}"

export OPENAI_API_KEY="${OPENAI_API_KEY:-dummy-key}"

if [[ $# -gt 0 ]]; then
  exec /usr/local/bin/run-codex exec \
    --skip-git-repo-check \
    -c "openai_base_url=\"$BASE_URL\"" \
    -c 'model_provider="openai"' \
    -c "model=\"$MODEL_NAME\"" \
    --dangerously-bypass-approvals-and-sandbox \
    "$@"
fi

exec /usr/local/bin/run-codex \
  -c "openai_base_url=\"$BASE_URL\"" \
  -c 'model_provider="openai"' \
  -c "model=\"$MODEL_NAME\""
