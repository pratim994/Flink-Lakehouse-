#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

failed=0
echo "[RUN] Python unit tests"
if python3 -m unittest discover -s soda -p 'test_*.py'; then echo "[PASS] Python unit tests"; else echo "[FAIL] Python unit tests"; failed=1; fi

if ! command -v docker >/dev/null; then
  echo "[SKIP] Docker Compose and integration checks (docker is unavailable)"
  exit "$failed"
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "[SKIP] Docker Compose validation and integration checks (plugin unavailable)"
  exit "$failed"
fi
echo "[RUN] Compose config validation"
docker compose config -q || { echo "[FAIL] Compose config validation"; exit 1; }
echo "[PASS] Compose config validation"
if docker compose ps --status running --services | grep -qx trino; then
  echo "[RUN] Live stack checks"
  if docker compose exec -T soda python data_quality_monitor.py --once; then
    echo "[PASS] Live quality scan"
  else
    echo "[FAIL] Quality scan or Trino readiness"
    failed=1
  fi
  for table in products sales; do
    if docker compose exec -T trino trino --execute "SELECT count(*) FROM iceberg.demo.$table"; then
      echo "[PASS] Trino query iceberg.demo.$table"
    else
      echo "[FAIL] Trino query iceberg.demo.$table"
      failed=1
    fi
  done
  echo "[RUN] Superset Trino/dashboard check"
  if docker compose exec -T superset python /superset/validate_setup.py; then
    echo "[PASS] Superset Trino/dashboard check"
  else
    echo "[FAIL] Superset Trino/dashboard check"
    failed=1
  fi
  for integration in scripts/test_cdc.sh scripts/test_quality.sh scripts/test_recovery.sh; do
    echo "[RUN] $integration"
    if "$integration"; then echo "[PASS] $integration"; else echo "[FAIL] $integration"; failed=1; fi
  done
else
  echo "[SKIP] Live integration checks (stack is not running)"
fi
exit "$failed"
