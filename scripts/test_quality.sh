#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Missing .env; copy .env.example to .env first." >&2; exit 1; }
set -a; source .env; set +a

SALE_ID=9900003
mysql() {
  docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
    mysql -uroot --batch --skip-column-names appdb -e "$1"
}
trino() { docker compose exec -T trino trino --output-format TSV --execute "$1" 2>/dev/null; }
cleanup() { mysql "DELETE FROM sales WHERE id=$SALE_ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
mysql "INSERT INTO sales (id, product_id, qty, price, sale_ts) VALUES ($SALE_ID, 1, -2, -3.00, CURRENT_TIMESTAMP)"
found=0
for _ in $(seq 1 90); do
  found="$(trino "SELECT count(*) FROM iceberg.demo.sales WHERE id=$SALE_ID AND qty < 0 AND price < 0" || true)"
  [[ "$found" == "1" ]] && break
  sleep 2
done
[[ "$found" == "1" ]] || { echo "Invalid quality test row did not reach Iceberg." >&2; exit 1; }
output="$(docker compose exec -T soda python data_quality_monitor.py --once 2>&1)" && status=0 || status=$?
if [[ "$status" -eq 0 ]]; then
  echo "[FAIL] quality monitor accepted intentionally invalid quantity and price." >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
grep -q 'FAIL sales qty positive' <<<"$output" || { echo "$output" >&2; echo "Expected quantity check to fail." >&2; exit 1; }
grep -q 'FAIL sales price positive' <<<"$output" || { echo "$output" >&2; echo "Expected price check to fail." >&2; exit 1; }
echo "[PASS] one-shot quality monitor returned nonzero for invalid quantity and price"
cleanup
deleted=0
for _ in $(seq 1 90); do
  deleted="$(trino "SELECT count(*) FROM iceberg.demo.sales WHERE id=$SALE_ID" || true)"
  [[ "$deleted" == "0" ]] && break
  sleep 2
done
[[ "$deleted" == "0" ]] || { echo "Test row cleanup did not reach Iceberg." >&2; exit 1; }
docker compose exec -T soda python data_quality_monitor.py --once
