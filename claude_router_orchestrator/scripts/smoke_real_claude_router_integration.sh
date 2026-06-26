#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="${1:-${REPO_ROOT}/examples/hello-python}"
TASK="${2:-Edit tests/test_placeholder.py so it contains a deterministic assertion assert 1 + 1 == 2 and keep the file minimal.}"
RUN_ROOT="${ORCH_RUN_ROOT:-${REPO_ROOT}/orchestrator-claude}"
BASE_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:3456}"
HEALTH_URL="${CCR_HEALTH_URL:-${BASE_URL%/}/health}"
ALLOW_AUTOSTART="${ALLOW_AUTOSTART:-0}"
MAX_CHILDREN="${CLAUDE_MAX_CHILDREN:-2}"
MAX_CHILD_INVOCATIONS="${ORCH_MAX_CHILD_INVOCATIONS:-6}"

need_cmd() {
  local name="${1:?name required}"
  command -v "$name" >/dev/null 2>&1 || {
    echo "missing required command: $name" >&2
    exit 1
  }
}

need_cmd bash
need_cmd python3
need_cmd jq
need_cmd curl
need_cmd claude

if [[ "$ALLOW_AUTOSTART" = "1" ]]; then
  if [[ -n "${START_CCR_BIN:-}" ]]; then
    "${START_CCR_BIN}" >/dev/null 2>&1 || true
  else
    echo "ALLOW_AUTOSTART=1 was set, but START_CCR_BIN was not provided." >&2
    echo "Refusing to guess a router startup command because this smoke test must not modify your router settings." >&2
    exit 1
  fi
fi

if ! curl -fsS -H "x-api-key: ${ANTHROPIC_AUTH_TOKEN:-local-test-key}" "$HEALTH_URL" >/dev/null 2>&1; then
  echo "Router health check failed at: $HEALTH_URL" >&2
  echo "Start your existing Claude Code Router first, or rerun with ALLOW_AUTOSTART=1 and START_CCR_BIN=/path/to/your/start-command." >&2
  exit 1
fi

cat > "${PROJECT_ROOT}/tests/test_placeholder.py" <<'EOF'
def test_placeholder():
    assert True
EOF

export CCR_AUTOSTART=0
export CLAUDE_MAX_CHILDREN="$MAX_CHILDREN"
export ORCH_MAX_CHILD_INVOCATIONS="$MAX_CHILD_INVOCATIONS"

bash "${SCRIPT_DIR}/orchestrate_claude_to_claude.sh" \
  "$TASK" \
  "$PROJECT_ROOT"

LATEST_RUN="$(find "$RUN_ROOT" -maxdepth 1 -type d -name 'run-*' | sort | tail -n 1)"
SUMMARY_FILE="${LATEST_RUN}/summary.json"

python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
metrics = summary.get("metrics", {})

ok = True
reasons = []
if metrics.get("workers_run", 0) < 1:
    ok = False
    reasons.append("no worker was executed")
if metrics.get("workers_with_verified_changes", 0) < 1:
    ok = False
    reasons.append("no verified file change was detected")
if metrics.get("workers_child_limit_blocked", 0) > metrics.get("workers_run", 0):
    ok = False
    reasons.append("child limit metrics look inconsistent")

result = {
    "integration_ok": ok,
    "reasons": reasons,
    "run_id": summary.get("run_id"),
    "scope_path": summary.get("scope_path"),
    "strategy": summary.get("strategy"),
    "metrics": metrics,
}
print(json.dumps(result, indent=2))
if not ok:
    sys.exit(1)
PY
