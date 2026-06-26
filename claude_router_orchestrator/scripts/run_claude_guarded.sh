#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/claude_router_common.sh"

RUN_DIR="${CLAUDE_RUN_DIR:-$(ccr_default_run_dir)/guarded}"
OUTPUT_FILE="${CLAUDE_GUARDED_OUTPUT:-${RUN_DIR}/guarded.raw.txt}"
MAX_FILES="${GUARD_MAX_FILES:-2}"
MAX_LINES="${GUARD_MAX_LINES_PER_FILE:-160}"
MAX_BATCHES="${GUARD_MAX_BATCHES:-2}"

mkdir -p "$RUN_DIR"
ccr_register_main_process "$RUN_DIR" "main_guarded"
trap 'bash "${SCRIPT_DIR}/cleanup_claude_children.sh" "$RUN_DIR" "$$" >/dev/null 2>&1 || true; ccr_unregister_process "$RUN_DIR" "$$" >/dev/null 2>&1 || true' EXIT

read -r -d '' GUARDED_PREFIX <<EOF || true
You are running in GUARDED LOW-CONTEXT mode through Claude Code + router.

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
- Never request or generate long reasoning.
- Keep responses concise and action-oriented.
- If tool context looks too large, reduce scope again before proceeding.
- If asked to modify code, identify the exact target files before editing.
EOF

if [[ $# -eq 0 ]]; then
  cat <<EOF
Guarded Claude mode
- shortlist limit: ${MAX_FILES} files
- first-pass line limit: ${MAX_LINES} lines/file
- max batches before resummary: ${MAX_BATCHES}

Usage:
  bash ./scripts/run_claude_guarded.sh "Inspect src and find the smallest safe next code task"
EOF
  exit 0
fi

PROMPT="${GUARDED_PREFIX}

User request:
$*"

invoke_claude_router_prompt "$RUN_DIR" "main_guarded_prompt" "$OUTPUT_FILE" "$PROMPT" ""
cat "$OUTPUT_FILE"
