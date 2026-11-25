# Local Flink CDC and Iceberg Lakehouse

A  demonstration pipeline from MySQL through Flink CDC and Iceberg on MinIO to Trino, with Superset for analytics and a custom Trino based quality monitor. 

```text
MySQL 8.0 (products, sales) -> Flink 1.19.3 + MySQL CDC 3.2.0
                                -> Iceberg 1.10.0 (JDBC catalog in MySQL)
                                -> MinIO (S3FileIO) -> Trino 477 -> Superset 3.1.0
                                                          \-> custom quality monitor
```

## Prerequisites

- Docker Engine with Compose plugin and Python 3.9+ on the host
- 8 GB RAM recommended; images and seeded data need several GB of free disk
- The stack uses locally scoped development credentials from `.env.example`. Change them before exposing ports or sharing the machine.

## Start and stop

```bash
cp .env.example .env
# Edit .env before starting.
docker compose config -q
docker compose up -d --build
./scripts/status.sh
```

MySQL is published on host port `MYSQL_PORT` (3307 by default) and Trino on `TRINO_PORT` (8082 by default); containers use service ports 3306 and 8080. These defaults avoid common local port collisions. The MySQL and MinIO data, Flink checkpoints, and Superset metadata use named volumes. Normal shutdown preserves them:

```bash
docker compose down
```

Do not add `-v` unless you intend to remove all named data volumes. MySQL initialization SQL only runs when its data directory is first created; edits to `sql/init.sql` do not reseed an existing database.

## Submit and manage CDC jobs

Submit once after the services are healthy:

```bash
./scripts/submit-jobs.sh
```

That script applies the DDL in `jobs/job.sql` (no writers) and submits exactly two independent streaming jobs, `cdc-products-to-iceberg` and `cdc-sales-to-iceberg`. Each job uses initial snapshot followed by binlog changes. Do not submit `job.sql` as a streaming pipeline or run the job files a second time; Flink SQL Client does not deduplicate submissions.

Inspect jobs and service health:

```bash
./scripts/status.sh
docker compose exec jobmanager /opt/flink/bin/flink list -r
```

Stop the writers via Flink's cancel command after reading job IDs from the list:

```bash
docker compose exec jobmanager /opt/flink/bin/flink cancel <job-id>
```

To restart a canceled pipeline, rerun `./scripts/submit-jobs.sh`. For crash recovery, a running JobManager retries failed jobs from checkpoint state; the checkpoint directory is on a persistent Docker volume. Automatic restoration of a submitted job after replacing the JobManager container is not configured or verified; resubmit manually if needed. No end-to-end exactly-once claim is made.

## CDC table semantics

Iceberg targets are format v2 tables with `write.upsert.enabled=true` and primary keys matching MySQL IDs. This enables keyed UPDATE and DELETE handling through Iceberg equality deletes. The SQL source and sink types are aligned with `sql/init.sql`. Correctness still depends on the installed connector/runtime combination and must be confirmed with the live CDC integration checks; those checks have not yet run in this environment.

## Validate

```bash
python3 -m unittest discover -s soda -p 'test_*.py'
./scripts/validate.sh
```

`validate.sh` always runs the monitor unit tests and validates Compose configuration. With a running stack it also runs the custom quality scan, Trino queries, Superset connection/dashboard check, CDC mutation test, invalid-data test, and TaskManager recovery test. When the stack is stopped, it reports live integration checks as skipped.

## Quality monitor

The `soda/` directory name is historical. This is a custom Python monitor using Trino's HTTP statement API, not Soda Core. It checks required fields, product and sale key uniqueness, SKU format, positive sale quantity and price, product references via a join, and sale timestamp freshness. The freshness threshold defaults to 8760 hours and can be changed with `FRESHNESS_MAX_HOURS` in `.env`.

```bash
docker compose exec soda python data_quality_monitor.py --once
docker compose logs -f soda
```

One-shot failure returns a nonzero status; the periodic service logs failures and continues at `MONITOR_INTERVAL_SECONDS` intervals.

## Trino and Superset

Endpoints: Flink UI `http://localhost:${FLINK_UI_PORT:-8083}`, MinIO console `http://localhost:9001`, Trino `http://localhost:${TRINO_PORT:-8082}`, Superset `http://localhost:8088`. Use credentials from `.env`; MinIO uses `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`, and Superset uses `SUPERSET_ADMIN_USERNAME` and `SUPERSET_ADMIN_PASSWORD`.

Example Trino queries:

```sql
SELECT p.name, count(*) AS sale_count, sum(s.qty) AS units,
       sum(s.qty * s.price) AS revenue
FROM iceberg.demo.sales s JOIN iceberg.demo.products p ON p.id = s.product_id
GROUP BY p.name ORDER BY revenue DESC;

SELECT CAST(sale_ts AS date) AS sale_date, sum(qty * price) AS revenue
FROM iceberg.demo.sales GROUP BY CAST(sale_ts AS date) ORDER BY sale_date;
```

Superset uses the internal Trino hostname `trino`. To create or update the dashboard without duplicates, load `.env` into your shell and run:

```bash
set -a; source .env; set +a
python3 -m pip install -r superset/requirements.txt
python3 superset/setup_dashboard.py
```

This creates product sale count, unit volume, revenue (`SUM(qty * price)`), and daily revenue trend charts. The script upserts named objects and links chart IDs to the dashboard. Its configured SQLAlchemy Trino URI returned the live sales count during validation, and a second provisioning run reused all four charts and the dashboard.

## Configuration and versions

The Flink image pins Flink 1.19.3, MySQL CDC 3.2.0, Iceberg runtime and AWS bundle 1.10.0, MySQL Connector/J 8.4.0, and Hadoop client 3.3.6. The image built successfully and both jobs submitted and read the seeded data in this environment. Compose pins MySQL 8.0.46, Trino 477, and Superset 3.1.0. No performance benchmark was run; previous throughput, latency, and quality-check timing claims have been removed.

MinIO withdrew its public server/client images from their prior registries, so Compose pins exact upstream image digests mirrored in [GHCR](https://github.com/Projekt-Manager-Org/minio-mirror). The mirror repository records the original MinIO source commits and matching amd64 digests; operators should review that provenance before using it outside a local demonstration.

The deterministic mutation, quality-failure, and TaskManager recovery checks are available as `scripts/test_cdc.sh`, `scripts/test_quality.sh`, and `scripts/test_recovery.sh`. `./scripts/validate.sh` runs them when the stack is active; they create and delete only reserved test IDs `990001`/`9900001`, `9900003`, and `990002`/`9900002`.

