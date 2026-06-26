#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="${REPO_ROOT}/examples/hello-python"

export CLAUDE_BIN="${CLAUDE_BIN:-python3}"
export CLAUDE_BIN_EXTRA="${CLAUDE_BIN_EXTRA:-${SCRIPT_DIR}/mock_claude_router_cli.py}"
export CCR_AUTOSTART="${CCR_AUTOSTART:-0}"

cat > "${PROJECT_ROOT}/tests/test_placeholder.py" <<'EOF'
def test_placeholder():
    assert True
EOF

bash "${SCRIPT_DIR}/orchestrate_claude_to_claude.sh" \
  "Edit tests/test_placeholder.py so it contains a deterministic assertion assert 1 + 1 == 2 and keep the file minimal." \
  "$PROJECT_ROOT"
