#!/usr/bin/env bash
set -euo pipefail

MODEL_NAME="${MODEL_NAME:-qwen3:4b}"

if [[ $# -gt 0 ]]; then
  exec /usr/local/bin/run-codex exec --oss --local-provider ollama --model "$MODEL_NAME" --dangerously-bypass-approvals-and-sandbox "$@"
fi

exec /usr/local/bin/run-codex --oss --local-provider ollama --model "$MODEL_NAME"
