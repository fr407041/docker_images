#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-claude-router-bundle-test:ubuntu22}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/claude_orchestrator}"
CONTAINER_PLAYBOOK_ROOT="${CONTAINER_PLAYBOOK_ROOT:-/opt/codex-claude-server-playbook}"

docker build \
  -f "${REPO_ROOT}/docker/claude-router-bundle-test/Dockerfile" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}"

docker run --rm \
  -e INSTALL_ROOT="${INSTALL_ROOT}" \
  -e CONTAINER_PLAYBOOK_ROOT="${CONTAINER_PLAYBOOK_ROOT}" \
  "${IMAGE_TAG}" \
  bash -lc "
    set -euo pipefail
    cd '${CONTAINER_PLAYBOOK_ROOT}'
    bash ./scripts/install_claude_router_orchestrator_bundle.sh '${INSTALL_ROOT}' >/tmp/bundle-path.txt
    cd '${INSTALL_ROOT}'
    bash ./scripts/evaluate_claude_single_file.sh >/tmp/eval-single.log 2>&1
    bash ./scripts/evaluate_claude_multi_round.sh 3 >/tmp/eval-multi.log 2>&1
    bash ./scripts/evaluate_claude_child_limits.sh >/tmp/eval-child-limit.log 2>&1
    bash ./scripts/evaluate_claude_fail_replan.sh >/tmp/eval-fail-replan.log 2>&1
    bash ./scripts/evaluate_claude_timeout_recovery.sh >/tmp/eval-timeout.log 2>&1
    bash ./scripts/evaluate_claude_bad_planner.sh >/tmp/eval-bad-planner.log 2>&1
    bash ./scripts/evaluate_claude_needs_replan.sh >/tmp/eval-needs-replan.log 2>&1
    bash ./scripts/evaluate_claude_false_success_guard.sh >/tmp/eval-false-success.log 2>&1 || true
    bash ./scripts/evaluate_claude_replan_loop_guard.sh >/tmp/eval-loop-guard.log 2>&1 || true
    python3 - <<'PY'
import json
from pathlib import Path

run_root = Path('${INSTALL_ROOT}/orchestrator-claude')
latest = sorted([p for p in run_root.glob('run-*') if p.is_dir()])[-1]
summary = json.loads((latest / 'summary.json').read_text(encoding='utf-8'))
print(json.dumps(summary, indent=2))
PY
  "
