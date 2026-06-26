#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="${REPO_ROOT}/examples/hello-python"

export CLAUDE_BIN="${CLAUDE_BIN:-python3}"
export CLAUDE_BIN_EXTRA="${CLAUDE_BIN_EXTRA:-${SCRIPT_DIR}/mock_claude_router_cli.py}"
export CCR_AUTOSTART="${CCR_AUTOSTART:-0}"
export MOCK_CLAUDE_BAD_PLANNER=1
export ORCH_MAX_FILES_PER_JOB="${ORCH_MAX_FILES_PER_JOB:-3}"

cat > "${PROJECT_ROOT}/tests/test_placeholder.py" <<'EOF'
def test_placeholder():
    assert True
EOF

bash "${SCRIPT_DIR}/orchestrate_claude_to_claude.sh" \
  "Inspect this tiny repo, find the most relevant test file, and update it to use the deterministic assertion assert 1 + 1 == 2 while keeping the file minimal." \
  "$PROJECT_ROOT"
