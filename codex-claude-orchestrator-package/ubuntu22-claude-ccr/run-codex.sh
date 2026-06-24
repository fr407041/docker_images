#!/usr/bin/env bash
set -euo pipefail

cd "${CODEX_WORKDIR:-/workspace}"

if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
  export OPENAI_BASE_URL
fi

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  export OPENAI_API_KEY
fi

if [[ -f "${CODEX_CONFIG_FILE:-}" ]]; then
  exec codex --config "${CODEX_CONFIG_FILE}" "${@}"
fi

exec codex "${@}"
