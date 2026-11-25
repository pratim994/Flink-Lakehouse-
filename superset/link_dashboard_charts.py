#!/usr/bin/env python3
"""Idempotently attach provisioned slices to a Superset dashboard."""

import sys

from superset.app import create_app


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: link_dashboard_charts.py DASHBOARD_ID CHART_ID,CHART_ID,...")
    dashboard_id = int(sys.argv[1])
    chart_ids = [int(value) for value in sys.argv[2].split(",") if value]
    if not chart_ids:
        raise SystemExit("at least one chart ID is required")

    app = create_app()
    with app.app_context():
        from superset import db
        from superset.models.dashboard import Dashboard
        from superset.models.slice import Slice

        dashboard = db.session.query(Dashboard).filter_by(id=dashboard_id).one()
        slices = db.session.query(Slice).filter(Slice.id.in_(chart_ids)).all()
        if {chart.id for chart in slices} != set(chart_ids):
            raise SystemExit("one or more chart IDs do not exist")
        dashboard.slices = slices
        db.session.commit()
        print(f"Linked chart IDs {sorted(chart_ids)} to dashboard {dashboard_id}")


if __name__ == "__main__":
    main()
