#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="${REPO_ROOT}/examples/multi-file-python"

export CLAUDE_BIN="${CLAUDE_BIN:-python3}"
export CLAUDE_BIN_EXTRA="${CLAUDE_BIN_EXTRA:-${SCRIPT_DIR}/mock_claude_router_cli.py}"
export CCR_AUTOSTART="${CCR_AUTOSTART:-0}"
export MOCK_CLAUDE_NEEDS_REPLAN_ON_MULTI_FILE=1
export ORCH_MAX_FAIL_REPLANS_PER_JOB="${ORCH_MAX_FAIL_REPLANS_PER_JOB:-1}"

cat > "${PROJECT_ROOT}/tests/test_math_utils.py" <<'EOF'
def test_placeholder():
    assert True
EOF

bash "${SCRIPT_DIR}/orchestrate_claude_to_claude.sh" \
  "Edit tests/test_math_utils.py so it contains a deterministic assertion for add(1, 1) == 2 and keep the file minimal." \
  "$PROJECT_ROOT"
