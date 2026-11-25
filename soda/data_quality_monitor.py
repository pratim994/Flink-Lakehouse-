#!/usr/bin/env python3
"""Small custom Trino quality monitor; this does not use Soda Core."""

import argparse
import os
import sys
import time
from datetime import datetime, timezone

import requests

HOST = os.getenv("TRINO_HOST", "trino")
PORT = int(os.getenv("TRINO_PORT", "8080"))
CATALOG = os.getenv("TRINO_CATALOG", "iceberg")
SCHEMA = os.getenv("TRINO_SCHEMA", "demo")
USER = os.getenv("TRINO_USER", "quality-monitor")
POLL_INTERVAL = float(os.getenv("TRINO_POLL_INTERVAL", "0.2"))
MAX_POLLS = int(os.getenv("TRINO_MAX_POLLS", "300"))
FRESHNESS_HOURS = int(os.getenv("FRESHNESS_MAX_HOURS", "8760"))
URL = f"http://{HOST}:{PORT}/v1/statement"


def query(sql, session=requests):
    headers = {
        "X-Trino-User": USER,
        "X-Trino-Catalog": CATALOG,
        "X-Trino-Schema": SCHEMA,
    }
    response = session.post(URL, headers=headers, data=sql, timeout=15)
    response.raise_for_status()
    result = response.json()
    rows = []
    for _ in range(MAX_POLLS):
        if result.get("error"):
            raise RuntimeError(result["error"].get("message", "Trino query failed"))
        rows.extend(result.get("data", []))
        next_uri = result.get("nextUri")
        if not next_uri:
            return rows
        response = session.get(next_uri, headers=headers, timeout=15)
        response.raise_for_status()
        result = response.json()
        if result.get("stats", {}).get("state") in ("FAILED", "CANCELED"):
            raise RuntimeError(result.get("error", {}).get("message", "Trino query failed"))
    raise TimeoutError("Trino query exceeded polling limit")


def count_check(name, sql, valid=lambda n: n == 0):
    rows = query(sql)
    value = rows[0][0]
    return name, value, bool(valid(value))


def run_checks():
    # One row per check; violations are selected so zero means pass.
    checks = [
        count_check("products table nonempty", "SELECT count(*) FROM products", valid=lambda n: n > 0),
        count_check("products.id required", "SELECT count_if(id IS NULL) FROM products"),
        count_check("products.sku required", "SELECT count_if(sku IS NULL OR trim(sku) = '') FROM products"),
        count_check("products.name required", "SELECT count_if(name IS NULL OR trim(name) = '') FROM products"),
        count_check("products.id unique", "SELECT count(*) - count(DISTINCT id) FROM products"),
        count_check("products.sku unique", "SELECT count(*) - count(DISTINCT sku) FROM products"),
        count_check("products SKU format", "SELECT count_if(NOT regexp_like(sku, '^P-[0-9]{3}$')) FROM products WHERE sku IS NOT NULL"),
        count_check("sales table nonempty", "SELECT count(*) FROM sales", valid=lambda n: n > 0),
        count_check("sales required fields", "SELECT count_if(id IS NULL OR product_id IS NULL OR qty IS NULL OR price IS NULL OR sale_ts IS NULL) FROM sales"),
        count_check("sales.id unique", "SELECT count(*) - count(DISTINCT id) FROM sales"),
        count_check("sales qty positive", "SELECT count_if(qty <= 0) FROM sales WHERE qty IS NOT NULL"),
        count_check("sales price positive", "SELECT count_if(price <= 0) FROM sales WHERE price IS NOT NULL"),
        count_check("sales product reference", "SELECT count(*) FROM sales s LEFT JOIN products p ON s.product_id = p.id WHERE p.id IS NULL"),
        count_check(
            f"sales freshness <= {FRESHNESS_HOURS}h",
            f"SELECT CASE WHEN max(sale_ts) IS NULL OR max(sale_ts) < current_timestamp - INTERVAL '{FRESHNESS_HOURS}' HOUR THEN 1 ELSE 0 END FROM sales",
        ),
    ]
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true", help="run once and exit nonzero on failed checks")
    parser.add_argument("--interval", type=int, default=int(os.getenv("MONITOR_INTERVAL_SECONDS", "300")))
    args = parser.parse_args()
    while True:
        print(f"\nQuality scan at {datetime.now(timezone.utc).isoformat()}", flush=True)
        try:
            checks = run_checks()
        except Exception as exc:
            print(f"FAIL Trino query/connection: {type(exc).__name__}: {exc}", flush=True)
            if args.once:
                return 1
        else:
            for name, value, passed in checks:
                print(f"{'PASS' if passed else 'FAIL'} {name}: {value}", flush=True)
            passed = sum(ok for _, _, ok in checks)
            print(f"Summary: {passed}/{len(checks)} checks passed", flush=True)
            if args.once:
                return 0 if passed == len(checks) else 1
        if args.once:
            return 1
        time.sleep(max(args.interval, 1))


if __name__ == "__main__":
    sys.exit(main())
