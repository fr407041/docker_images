#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/claude_router_common.sh"

RUN_DIR="${1:?Usage: cleanup_claude_children.sh <run_dir> [keep_pid ...]}"
shift || true

ccr_cleanup_problem_children "$RUN_DIR" "$@"
