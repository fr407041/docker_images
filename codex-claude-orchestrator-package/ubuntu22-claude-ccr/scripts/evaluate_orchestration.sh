#!/usr/bin/env bash
set -euo pipefail

TASK="${1:-Inspect the hello-python repo, find the smallest next code task, and keep scope narrow.}"
SCOPE_PATH="${2:-/workspace/linux_remote/ubuntu22-claude-ccr/hello-python}"
RUN_ROOT="${ORCH_RUN_ROOT:-/workspace/linux_remote/ubuntu22-claude-ccr/orchestrator}"

echo "== Planning-only evaluation =="
ORCH_EXECUTE_WORKERS=0 bash /workspace/linux_remote/ubuntu22-claude-ccr/scripts/orchestrate_codex_to_claude.sh "$TASK" "$SCOPE_PATH"

LATEST_PLAN="$(find "$RUN_ROOT" -maxdepth 1 -type d -name 'run-*' | sort | tail -n 1)"
if [[ -n "${LATEST_PLAN:-}" && -f "${LATEST_PLAN}/summary.json" ]]; then
  echo ""
  echo "== Planning metrics =="
  jq '.metrics' "${LATEST_PLAN}/summary.json"
fi

echo ""
echo "== Worker execution evaluation =="
ORCH_EXECUTE_WORKERS=1 bash /workspace/linux_remote/ubuntu22-claude-ccr/scripts/orchestrate_codex_to_claude.sh "$TASK" "$SCOPE_PATH"

LATEST_EXEC="$(find "$RUN_ROOT" -maxdepth 1 -type d -name 'run-*' | sort | tail -n 1)"
if [[ -n "${LATEST_EXEC:-}" && -f "${LATEST_EXEC}/summary.json" ]]; then
  echo ""
  echo "== Execution metrics =="
  jq '.metrics' "${LATEST_EXEC}/summary.json"
  echo ""
  echo "Run directory: ${LATEST_EXEC}"
fi
