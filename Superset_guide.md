# Superset and Trino

Open Superset at `http://localhost:8088`. Credentials come from `SUPERSET_ADMIN_USERNAME` and `SUPERSET_ADMIN_PASSWORD` in `.env`.

When adding a database in Superset, use the Docker network hostname `trino` and port `8080`. The Iceberg catalog is `iceberg`; tables are in schema `demo`. Superset's browser-facing URL is localhost, while its database connection must use the Compose service name.

After the Trino catalog and tables are available, create or update the supplied dashboard:

```bash
set -a; source .env; set +a
python3 -m pip install -r superset/requirements.txt
python3 superset/setup_dashboard.py
```

It provisions product sale count, total units, revenue using `qty * price`, and daily revenue trend charts, then links them to the dashboard. The operation can be rerun without creating another copy. See the root README for direct Trino query examples.
