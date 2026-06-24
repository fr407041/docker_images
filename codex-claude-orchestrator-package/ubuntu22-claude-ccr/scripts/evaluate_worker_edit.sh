#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/workspace/linux_remote/ubuntu22-claude-ccr/hello-python"
RUN_ROOT="/workspace/linux_remote/ubuntu22-claude-ccr/orchestrator/manual-worker-edit"
RUN_ID="run-$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUN_ROOT}/${RUN_ID}"
JOBS_DIR="${RUN_DIR}/jobs"
RESULTS_DIR="${RUN_DIR}/results"

mkdir -p "$JOBS_DIR" "$RESULTS_DIR"
cd "$PROJECT_ROOT"

cat > tests/test_placeholder.py <<'EOF'
def test_placeholder():
    assert True
EOF

cat > "${JOBS_DIR}/job-001.json" <<'EOF'
{
  "id": "job-001",
  "scope_path": "/workspace/linux_remote/ubuntu22-claude-ccr/hello-python",
  "title": "Add a stronger placeholder assertion",
  "instruction": "Edit tests/test_placeholder.py so it contains a deterministic assertion assert 1 + 1 == 2 and keep the file minimal.",
  "files": [
    "tests/test_placeholder.py"
  ],
  "success_check": "tests/test_placeholder.py contains assert 1 + 1 == 2 and pytest -q passes",
  "require_change": true,
  "test_command": "pytest -q"
}
EOF

bash /workspace/linux_remote/ubuntu22-claude-ccr/scripts/worker_claude_router.sh "${JOBS_DIR}/job-001.json" >/dev/null || true

STATUS_FILE="${RESULTS_DIR}/job-001.status.json"
TEST_FILE="${PROJECT_ROOT}/tests/test_placeholder.py"

echo "== Worker edit status =="
jq . "$STATUS_FILE"
echo ""
echo "== Updated test file =="
cat "$TEST_FILE"

if [[ -f "${RESULTS_DIR}/job-001.test.txt" ]]; then
  echo ""
  echo "== pytest output =="
  cat "${RESULTS_DIR}/job-001.test.txt"
fi
