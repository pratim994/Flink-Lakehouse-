#!/usr/bin/env python3
"""Validate the Superset Trino URI and provisioned chart/dashboard metadata."""

from sqlalchemy import create_engine, text

TRINO_URI = "trino://admin@trino:8080/iceberg"
EXPECTED_CHARTS = {
    "Sales Count by Product",
    "Total Sales Volume",
    "Total Revenue",
    "Daily Revenue Trend",
}


def main():
    engine = create_engine(TRINO_URI)
    with engine.connect() as connection:
        sales_count = connection.execute(text("SELECT count(*) FROM demo.sales")).scalar()
    if not sales_count or sales_count < 1:
        raise SystemExit("[FAIL] Superset Trino URI returned no sales")
    print(f"[PASS] Superset SQLAlchemy Trino connection: {sales_count} sales")

    from superset.app import create_app
    app = create_app()
    with app.app_context():
        from superset import db
        from superset.models.dashboard import Dashboard

        dashboard = db.session.query(Dashboard).filter_by(slug="sales-analytics").one_or_none()
        if dashboard is None:
            raise SystemExit("[FAIL] Sales Analytics Dashboard is missing")
        names = {chart.slice_name for chart in dashboard.slices}
        if names != EXPECTED_CHARTS:
            raise SystemExit(f"[FAIL] Dashboard chart set mismatch: {sorted(names)}")
        revenue = next(chart for chart in dashboard.slices if chart.slice_name == "Total Revenue")
        if "SUM(qty * price)" not in revenue.params:
            raise SystemExit("[FAIL] Revenue chart does not multiply quantity by unit price")
    print("[PASS] Superset dashboard has four linked analytics charts")


if __name__ == "__main__":
    main()
