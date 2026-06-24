#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/start-ccr

export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-local-test-key}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:3456}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
export DISABLE_PROMPT_CACHING="${DISABLE_PROMPT_CACHING:-1}"
export API_TIMEOUT_MS="${API_TIMEOUT_MS:-600000}"

cd "${CLAUDE_WORKDIR:-/workspace}"

declare -a claude_args
claude_args+=(--model "${CLAUDE_MODEL_ALIAS:-sonnet}")
claude_args+=(--permission-mode "${CLAUDE_PERMISSION_MODE:-bypassPermissions}")

if [[ -f ".claude/settings.docker.json" ]]; then
  claude_args+=(--settings ".claude/settings.docker.json")
fi

exec claude "${claude_args[@]}"
