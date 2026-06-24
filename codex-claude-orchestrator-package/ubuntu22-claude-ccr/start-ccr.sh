#!/usr/bin/env bash
set -euo pipefail

CCR_HOME="${HOME:-/home/claude}/.claude-code-router"

mkdir -p "${CCR_HOME}"
cp /opt/claude-ccr/router-config.json "${CCR_HOME}/config.json"

ccr restart >/tmp/ccr-restart.log 2>&1 || true

for _ in $(seq 1 20); do
  if curl -fsS -H 'x-api-key: local-test-key' http://127.0.0.1:3456/health >/dev/null 2>&1; then
    echo "CCR started with config ${CCR_HOME}/config.json"
    exit 0
  fi
  sleep 1
done

echo "CCR failed to become healthy" >&2
cat /tmp/ccr-restart.log >&2 || true
exit 1
