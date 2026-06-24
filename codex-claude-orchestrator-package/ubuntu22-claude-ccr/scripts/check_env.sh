#!/usr/bin/env bash
set -euo pipefail

echo "PWD=$(pwd)"
echo ""
echo "[docker]"
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}' 2>/dev/null || docker version
echo ""
echo "[compose]"
docker compose version
echo ""
echo "[host ollama]"
curl -fsS http://host.docker.internal:11434/api/tags || true
echo ""
echo "[host lm studio]"
curl -fsS http://host.docker.internal:1234/v1/models || true
