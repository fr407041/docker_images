#!/usr/bin/env bash
set -euo pipefail

MODEL_NAME="${MODEL_NAME:-qwen3:4b}"
BASE_URL="${OPENAI_BASE_URL:-http://host.docker.internal:11434/v1}"
MAX_FILES="${GUARD_MAX_FILES:-3}"
MAX_LINES="${GUARD_MAX_LINES_PER_FILE:-250}"
MAX_BATCHES="${GUARD_MAX_BATCHES:-3}"

export OPENAI_API_KEY="${OPENAI_API_KEY:-dummy-key}"

read -r -d '' GUARDED_PREFIX <<EOF || true
You are running in GUARDED LOW-CONTEXT mode.

Your first priority is to avoid context overflow and oversized output.
You must obey this workflow for every task:

Phase 1: Inventory only.
- Do not read whole folders.
- Start from file inventory and pattern search only.
- Produce a shortlist of at most ${MAX_FILES} files for the first pass.

Phase 2: Narrow before reading.
- Read only the minimum needed files.
- Read at most ${MAX_LINES} lines per file in the first pass.
- Prefer targeted symbol search over full-file reads.

Phase 3: Batch execution.
- Work in at most ${MAX_BATCHES} batches before re-summarizing.
- After each batch, emit a compact checkpoint:
  1. what was inspected
  2. what remains
  3. next smallest step

Phase 4: Stop expansion.
- If the task is still broad, do not continue expanding automatically.
- Return a decomposition plan and the smallest next actionable batch.

Hard rules:
- Never scan an entire large folder in one go.
- Never request or generate a long chain-of-thought.
- Keep responses concise and action-oriented.
- If tool context looks too large, reduce scope again before proceeding.
- If asked to modify code, identify the exact target files before editing.

User task follows below.
EOF

if [[ $# -gt 0 ]]; then
  USER_TASK="$*"
elif [[ -n "${CODEX_TASK:-}" ]]; then
  USER_TASK="${CODEX_TASK}"
else
  USER_TASK=""
fi

if [[ -n "${USER_TASK}" ]]; then
  exec /usr/local/bin/run-codex exec \
    --skip-git-repo-check \
    -c "openai_base_url=\"$BASE_URL\"" \
    -c 'model_provider="openai"' \
    -c "model=\"$MODEL_NAME\"" \
    --dangerously-bypass-approvals-and-sandbox \
    "${GUARDED_PREFIX}

User request:
${USER_TASK}"
fi

cat <<EOF
Guarded Codex mode
- model: ${MODEL_NAME}
- endpoint: ${BASE_URL}
- shortlist limit: ${MAX_FILES} files
- first-pass line limit: ${MAX_LINES} lines/file
- max batches before resummary: ${MAX_BATCHES}

Usage:
  bash ./scripts/run_codex_guarded.sh "Inspect src and fix the login bug"

This wrapper is optimized for smaller local models and token-overflow avoidance.
For interactive Codex UI, use the normal launcher and keep tasks narrow.
EOF
