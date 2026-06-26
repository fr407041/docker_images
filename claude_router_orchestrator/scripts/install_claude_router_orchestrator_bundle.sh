#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_ROOT="${1:-/opt/claude_orchestrator}"
TARGET_ROOT="$(python3 - "$TARGET_ROOT" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
)"

mkdir -p "${TARGET_ROOT}/scripts" "${TARGET_ROOT}/examples" "${TARGET_ROOT}/docker/claude-router-bundle-test"

copy_file() {
  local src="${1:?src required}"
  local dst="${2:?dst required}"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
}

copy_tree() {
  local src="${1:?src required}"
  local dst="${2:?dst required}"
  mkdir -p "$dst"
  cp -R "${src}/." "$dst/"
}

copy_file "${REPO_ROOT}/README.md" "${TARGET_ROOT}/README.md"
copy_file "${REPO_ROOT}/README.zh-TW.md" "${TARGET_ROOT}/README.zh-TW.md"
copy_file "${REPO_ROOT}/BUNDLE_INSTALL.zh-TW.md" "${TARGET_ROOT}/BUNDLE_INSTALL.zh-TW.md"
copy_file "${REPO_ROOT}/SAFE_PUBLISHING.md" "${TARGET_ROOT}/SAFE_PUBLISHING.md"

for file in \
  claude_router_common.sh \
  cleanup_claude_children.sh \
  evaluate_claude_bad_planner.sh \
  evaluate_claude_child_limits.sh \
  evaluate_claude_fail_replan.sh \
  evaluate_claude_false_success_guard.sh \
  evaluate_claude_multi_round.sh \
  evaluate_claude_needs_replan.sh \
  evaluate_claude_replan_loop_guard.sh \
  evaluate_claude_single_file.sh \
  evaluate_claude_timeout_recovery.sh \
  install_claude_router_orchestrator_bundle.sh \
  mock_claude_router_cli.py \
  orchestrate_claude_to_claude.sh \
  orchestrate_codex_to_claude.sh \
  run_claude_guarded.sh \
  smoke_real_claude_router_integration.sh \
  smoke_bundle_in_fresh_image.sh \
  worker_claude_router.sh \
  worker_claude_router_managed_single_file.sh
do
  copy_file "${REPO_ROOT}/scripts/${file}" "${TARGET_ROOT}/scripts/${file}"
done

copy_tree "${REPO_ROOT}/examples/hello-python" "${TARGET_ROOT}/examples/hello-python"
copy_tree "${REPO_ROOT}/examples/multi-file-python" "${TARGET_ROOT}/examples/multi-file-python"
copy_tree "${REPO_ROOT}/docker/claude-router-bundle-test" "${TARGET_ROOT}/docker/claude-router-bundle-test"

chmod +x "${TARGET_ROOT}/scripts/"*.sh

cat > "${TARGET_ROOT}/BUNDLE_MANIFEST.txt" <<EOF
Claude/router orchestration bundle installed at:
${TARGET_ROOT}

Included:
- main->child Claude/router orchestration scripts
- child process cap and safe cleanup helpers
- mock-based multi-round evaluation scripts
- fresh Docker image smoke test assets

Excluded on purpose:
- Claude Code installation flow
- Claude Code Router installation flow
- model selection or router model config changes
EOF

printf '%s\n' "${TARGET_ROOT}"
