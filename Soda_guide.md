# Data quality monitor

The `soda/` directory name is retained for compatibility, but this project does not run Soda Core. The service is a custom Python monitor that sends SQL to Trino's HTTP API.

Run one scan and use its exit code in automation:

```bash
docker compose exec soda python data_quality_monitor.py --once
```

The periodic service interval is configured with `MONITOR_INTERVAL_SECONDS` in `.env`; `FRESHNESS_MAX_HOURS` sets the maximum age allowed for the newest sale timestamp. Monitor output is available with `docker compose logs -f soda`.

Checks cover null required fields, unique product/sale IDs and SKU, SKU format, positive sale quantity and price, sales referencing an existing product, and freshness. A failed query is reported as a monitor failure. Unit tests for pass/fail interpretation run with `python3 -m unittest discover -s soda -p 'test_*.py'`.
