#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/claude_router_common.sh"

RUN_ROOT="${ORCH_RUN_ROOT:-${REPO_ROOT}/orchestrator-claude-limit-tests}"
RUN_ID="run-$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUN_ROOT}/${RUN_ID}"
JOBS_DIR="${RUN_DIR}/jobs"
RESULTS_DIR="${RUN_DIR}/results"
PROJECT_ROOT="${REPO_ROOT}/examples/hello-python"
mkdir -p "$JOBS_DIR" "$RESULTS_DIR"

export CLAUDE_RUN_DIR="$RUN_DIR"
export CLAUDE_BIN="python3"
export CLAUDE_BIN_EXTRA="${SCRIPT_DIR}/mock_claude_router_cli.py"
export CCR_AUTOSTART=0
export CLAUDE_MAX_CHILDREN=1

ccr_register_main_process "$RUN_DIR" "main_orchestrator" "$PROJECT_ROOT"

python3 -c "import time; time.sleep(60)" &
DUMMY_CHILD_PID=$!
ccr_register_process "$RUN_DIR" "child_worker" "$DUMMY_CHILD_PID" "seed-child" "$PROJECT_ROOT"

cat > "${JOBS_DIR}/job-001.json" <<EOF
{
  "id": "job-001",
  "scope_path": "${PROJECT_ROOT}",
  "title": "Limit guard check",
  "instruction": "Edit tests/test_placeholder.py so it contains a deterministic assertion assert 1 + 1 == 2 and keep the file minimal.",
  "files": [
    "tests/test_placeholder.py"
  ],
  "success_check": "tests/test_placeholder.py contains assert 1 + 1 == 2 and pytest -q passes",
  "require_change": true,
  "test_command": ""
}
EOF

set +e
bash "${SCRIPT_DIR}/worker_claude_router_managed_single_file.sh" "${JOBS_DIR}/job-001.json" >/dev/null
WORKER_EXIT=$?
set -e

STATUS_FILE="${RESULTS_DIR}/job-001.status.json"
STATUS="$(jq -r '.status' "$STATUS_FILE")"

CLEANUP_REPORT="$(bash "${SCRIPT_DIR}/cleanup_claude_children.sh" "$RUN_DIR" "$$")"

if kill -0 "$DUMMY_CHILD_PID" >/dev/null 2>&1; then
  wait "$DUMMY_CHILD_PID" >/dev/null 2>&1 || true
fi

jq -n \
  --arg status "$STATUS" \
  --arg cleanup_report "$CLEANUP_REPORT" \
  --argjson main_pid_survived true \
  --argjson worker_exit "$WORKER_EXIT" \
  '{
    status: $status,
    worker_exit: $worker_exit,
    main_pid_survived: $main_pid_survived,
    cleanup_report: ($cleanup_report | fromjson)
  }'
