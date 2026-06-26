#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROUNDS="${1:-3}"
SCOPE_PATH="${2:-${REPO_ROOT}/examples/multi-file-python}"
TASK="${3:-Edit tests/test_math_utils.py so it contains a deterministic assertion for add(1, 1) == 2 and keep the file minimal.}"
RUN_ROOT="${ORCH_RUN_ROOT:-${REPO_ROOT}/orchestrator-claude}"
REPORT_DIR="${REPO_ROOT}/benchmarks/claude-multi-round-$(date +%Y%m%d-%H%M%S)}"
REPORT_FILE="${REPORT_DIR}/summary.tsv"

mkdir -p "$REPORT_DIR"

export CLAUDE_BIN="python3"
export CLAUDE_BIN_EXTRA="${SCRIPT_DIR}/mock_claude_router_cli.py"
export CCR_AUTOSTART=0
export MOCK_CLAUDE_OVERFLOW_ON_MULTI_FILE=1
export ORCH_MAX_FILES_PER_JOB="${ORCH_MAX_FILES_PER_JOB:-2}"
export ORCH_MAX_JOBS="${ORCH_MAX_JOBS:-2}"
export CLAUDE_MAX_CHILDREN="${CLAUDE_MAX_CHILDREN:-2}"
export ORCH_MAX_CHILD_INVOCATIONS="${ORCH_MAX_CHILD_INVOCATIONS:-6}"

printf "round\tplanner_parse_ok\tworkers_failed\tworkers_overflowed\tworkers_need_replan\tworkers_child_limit_blocked\toverflow_retries\tworkers_with_verified_changes\n" >"$REPORT_FILE"

for round in $(seq 1 "$ROUNDS"); do
  cat > "${SCOPE_PATH}/tests/test_math_utils.py" <<'EOF'
def test_placeholder():
    assert True
EOF

  ORCH_EXECUTE_WORKERS=1 bash "${SCRIPT_DIR}/orchestrate_claude_to_claude.sh" \
    "$TASK" \
    "$SCOPE_PATH" >/tmp/claude-multi-round-${round}.log 2>&1 || true

  latest_run="$(find "$RUN_ROOT" -maxdepth 1 -type d -name 'run-*' | sort | tail -n 1)"
  summary_file="${latest_run}/summary.json"

  python3 - "$summary_file" "$round" >>"$REPORT_FILE" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
metrics = summary.get("metrics", {})
print(
    "\t".join(
        [
            sys.argv[2],
            str(summary.get("planner_parse_ok")),
            str(metrics.get("workers_failed")),
            str(metrics.get("workers_overflowed")),
            str(metrics.get("workers_need_replan")),
            str(metrics.get("workers_child_limit_blocked")),
            str(metrics.get("overflow_retries")),
            str(metrics.get("workers_with_verified_changes")),
        ]
    )
)
PY
done

cat "$REPORT_FILE"
