#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Missing .env; copy .env.example to .env first." >&2; exit 1; }
set -a; source .env; set +a

PRODUCT_ID=990001
SALE_ID=9900001
mysql() {
  docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
    mysql -uroot --batch --skip-column-names appdb -e "$1"
}
trino() {
  docker compose exec -T trino trino --output-format TSV --execute "$1" 2>/dev/null
}
cleanup() {
  mysql "DELETE FROM sales WHERE id=$SALE_ID; DELETE FROM products WHERE id=$PRODUCT_ID;" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

assert_eventually() {
  local sql="$1" expected="$2" description="$3" actual="" attempt
  for attempt in $(seq 1 90); do
    actual="$(trino "$sql" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
      echo "[PASS] $description"
      return 0
    fi
    sleep 2
  done
  echo "[FAIL] $description: expected [$expected], last got [$actual]" >&2
  return 1
}

mysql "INSERT INTO products (id, sku, name) VALUES ($PRODUCT_ID, 'P-901', 'CDC Test Product')"
assert_eventually "SELECT sku || '|' || name FROM iceberg.demo.products WHERE id=$PRODUCT_ID" \
  "P-901|CDC Test Product" "product INSERT by id"
mysql "UPDATE products SET name='CDC Test Product Updated' WHERE id=$PRODUCT_ID"
assert_eventually "SELECT sku || '|' || name FROM iceberg.demo.products WHERE id=$PRODUCT_ID" \
  "P-901|CDC Test Product Updated" "product UPDATE by id"
mysql "DELETE FROM products WHERE id=$PRODUCT_ID"
assert_eventually "SELECT count(*) FROM iceberg.demo.products WHERE id=$PRODUCT_ID" \
  "0" "product DELETE by id"

# Recreate the product because sales has a source-side foreign key.
mysql "INSERT INTO products (id, sku, name) VALUES ($PRODUCT_ID, 'P-901', 'CDC Test Product')"
assert_eventually "SELECT count(*) FROM iceberg.demo.products WHERE id=$PRODUCT_ID" "1" "product reinsert"
mysql "INSERT INTO sales (id, product_id, qty, price, sale_ts) VALUES ($SALE_ID, $PRODUCT_ID, 2, 3.50, CURRENT_TIMESTAMP)"
assert_eventually "SELECT concat(cast(qty AS varchar), '|', cast(price AS varchar)) FROM iceberg.demo.sales WHERE id=$SALE_ID" \
  "2|3.50" "sale INSERT exactly once"
assert_eventually "SELECT count(*) FROM iceberg.demo.sales WHERE id=$SALE_ID" "1" "sale primary-key uniqueness"
mysql "UPDATE sales SET qty=4, price=5.50 WHERE id=$SALE_ID"
assert_eventually "SELECT concat(cast(qty AS varchar), '|', cast(price AS varchar)) FROM iceberg.demo.sales WHERE id=$SALE_ID" \
  "4|5.50" "sale UPDATE by id"
mysql "DELETE FROM sales WHERE id=$SALE_ID"
assert_eventually "SELECT count(*) FROM iceberg.demo.sales WHERE id=$SALE_ID" "0" "sale DELETE by id"
echo "CDC mutation smoke test passed; cleanup will remove only ids $PRODUCT_ID and $SALE_ID."
