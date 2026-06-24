#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-ollama}"

case "$TARGET" in
  ollama)
    BASE_URL="${OPENAI_BASE_URL:-http://host.docker.internal:11434/v1}"
    ;;
  lmstudio)
    BASE_URL="${OPENAI_BASE_URL:-http://host.docker.internal:1234/v1}"
    ;;
  *)
    BASE_URL="$TARGET"
    ;;
esac

MODELS_URL="${BASE_URL%/}/models"

echo "Testing: ${MODELS_URL}"
curl -fsS "$MODELS_URL"
