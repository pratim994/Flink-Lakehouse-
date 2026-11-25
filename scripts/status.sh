#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose ps
if docker compose ps --status running --services | grep -qx jobmanager; then
  docker compose exec -T jobmanager /opt/flink/bin/flink list -r || true
fi
