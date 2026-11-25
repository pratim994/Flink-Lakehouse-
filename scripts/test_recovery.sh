#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Missing .env; copy .env.example to .env first." >&2; exit 1; }
set -a; source .env; set +a

PRODUCT_ID=990002
SALE_ID=9900002
FLINK_URL="http://localhost:${FLINK_UI_PORT:-8083}"
mysql() {
  docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
    mysql -uroot --batch --skip-column-names appdb -e "$1"
}
trino() { docker compose exec -T trino trino --output-format TSV --execute "$1" 2>/dev/null; }
cleanup() {
  mysql "DELETE FROM sales WHERE id=$SALE_ID; DELETE FROM products WHERE id=$PRODUCT_ID;" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

job_ids="$(curl -fsS "$FLINK_URL/jobs/overview" | python3 -c 'import json,sys; jobs={j["name"]:j["jid"] for j in json.load(sys.stdin)["jobs"]}; print(jobs["cdc-products-to-iceberg"], jobs["cdc-sales-to-iceberg"])')"
read -r product_job_id sales_job_id <<<"$job_ids"
checkpoint_id() {
  curl -fsS "$FLINK_URL/jobs/$1/checkpoints" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("latest",{}).get("completed",{}).get("id",0))'
}
baseline_product=0
baseline_sales=0
for _ in $(seq 1 60); do
  baseline_product="$(checkpoint_id "$product_job_id" 2>/dev/null || echo 0)"
  baseline_sales="$(checkpoint_id "$sales_job_id" 2>/dev/null || echo 0)"
  [[ "$baseline_product" =~ ^[1-9][0-9]*$ && "$baseline_sales" =~ ^[1-9][0-9]*$ ]] && break
  sleep 2
done
[[ "$baseline_product" =~ ^[1-9][0-9]*$ && "$baseline_sales" =~ ^[1-9][0-9]*$ ]] || {
  echo "No successful baseline checkpoint observed for both CDC jobs." >&2; exit 1;
}
mysql "INSERT INTO products (id, sku, name) VALUES ($PRODUCT_ID, 'P-902', 'Recovery Test Product')"
for _ in $(seq 1 90); do
  value="$(trino "SELECT count(*) FROM iceberg.demo.products WHERE id=$PRODUCT_ID" || true)"
  [[ "$value" == "1" ]] && break
  sleep 2
done
[[ "${value:-}" == "1" ]] || { echo "Product did not reach Iceberg before recovery." >&2; exit 1; }

mysql "INSERT INTO sales (id, product_id, qty, price, sale_ts) VALUES ($SALE_ID, $PRODUCT_ID, 3, 7.25, CURRENT_TIMESTAMP)"
for _ in $(seq 1 90); do
  value="$(trino "SELECT count(*) FROM iceberg.demo.sales WHERE id=$SALE_ID" || true)"
  [[ "$value" == "1" ]] && break
  sleep 2
done
[[ "${value:-}" == "1" ]] || { echo "Sale did not reach Iceberg before recovery." >&2; exit 1; }

product_checkpoint=0
sales_checkpoint=0
for _ in $(seq 1 90); do
  product_checkpoint="$(checkpoint_id "$product_job_id" 2>/dev/null || echo 0)"
  sales_checkpoint="$(checkpoint_id "$sales_job_id" 2>/dev/null || echo 0)"
  if [[ "$product_checkpoint" =~ ^[0-9]+$ && "$sales_checkpoint" =~ ^[0-9]+$ ]] \
    && (( product_checkpoint > baseline_product && sales_checkpoint > baseline_sales )); then
    break
  fi
  sleep 2
done
[[ "$product_checkpoint" =~ ^[0-9]+$ && "$sales_checkpoint" =~ ^[0-9]+$ ]] \
  && (( product_checkpoint > baseline_product && sales_checkpoint > baseline_sales )) || {
  echo "Neither job completed a post-insert checkpoint (product=$product_checkpoint sales=$sales_checkpoint)." >&2; exit 1;
}
echo "[PASS] post-insert checkpoints completed (products=$product_checkpoint sales=$sales_checkpoint)"

echo "Restarting TaskManager with checkpoint volumes preserved..."
docker compose restart taskmanager
for _ in $(seq 1 90); do
  products="$(trino "SELECT count(*) FROM iceberg.demo.products WHERE id=$PRODUCT_ID" || true)"
  sales="$(trino "SELECT count(*) FROM iceberg.demo.sales WHERE id=$SALE_ID" || true)"
  [[ "$products" == "1" && "$sales" == "1" ]] && break
  sleep 2
done
[[ "${products:-}" == "1" && "${sales:-}" == "1" ]] || {
  echo "[FAIL] test records missing or duplicated after TaskManager recovery (products=$products sales=$sales)" >&2; exit 1;
}
running=0
for _ in $(seq 1 60); do
  running="$(curl -fsS "$FLINK_URL/jobs/overview" | python3 -c 'import json,sys; names={j["name"] for j in json.load(sys.stdin)["jobs"] if j["state"]=="RUNNING"}; print(int({"cdc-products-to-iceberg","cdc-sales-to-iceberg"} <= names))' 2>/dev/null || echo 0)"
  [[ "$running" == "1" ]] && break
  sleep 2
done
[[ "$running" == "1" ]] || { echo "[FAIL] both streaming jobs did not return to RUNNING after TaskManager restart." >&2; exit 1; }
mysql "UPDATE products SET name='Recovery Test Product Resumed' WHERE id=$PRODUCT_ID"
for _ in $(seq 1 90); do
  value="$(trino "SELECT name FROM iceberg.demo.products WHERE id=$PRODUCT_ID" || true)"
  [[ "$value" == "Recovery Test Product Resumed" ]] && break
  sleep 2
done
[[ "${value:-}" == "Recovery Test Product Resumed" ]] || { echo "[FAIL] product CDC did not resume after TaskManager restart." >&2; exit 1; }
products="$(trino "SELECT count(*) FROM iceberg.demo.products WHERE id=$PRODUCT_ID")"
sales="$(trino "SELECT count(*) FROM iceberg.demo.sales WHERE id=$SALE_ID")"
[[ "$products" == "1" && "$sales" == "1" ]] || { echo "[FAIL] duplicate test records after resumed CDC." >&2; exit 1; }
echo "[PASS] both CDC jobs resumed and a post-restart product update reached Iceberg"
echo "[PASS] product and sale each remain exactly once after TaskManager restart"
