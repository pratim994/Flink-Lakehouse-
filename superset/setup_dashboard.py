#!/usr/bin/env python3

import requests
import json
import time
import sys
import os
import subprocess

# Superset configuration
SUPERSET_URL = os.getenv("SUPERSET_URL", "http://localhost:8088")
USERNAME = os.getenv("SUPERSET_ADMIN_USERNAME", "admin")
PASSWORD = os.environ.get("SUPERSET_ADMIN_PASSWORD")
if not PASSWORD:
    raise SystemExit("SUPERSET_ADMIN_PASSWORD must be set")

def login():
    """Login to Superset and get access token"""
    session = requests.Session()
    
    # Get CSRF token
    resp = session.get(f"{SUPERSET_URL}/login/")
    if resp.status_code != 200:
        print(f"Failed to get login page: {resp.status_code}")
        return None
        
    # Login
    login_data = {
        "username": USERNAME,
        "password": PASSWORD,
        "provider": "db",
        "refresh": True,
    }
    
    resp = session.post(f"{SUPERSET_URL}/api/v1/security/login", json=login_data)
    if resp.status_code != 200:
        print(f"Login failed: {resp.status_code} - {resp.text}")
        return None
        
    access_token = resp.json().get("access_token")
    if not access_token:
        print("No access token received")
        return None
        
    session.headers.update({"Authorization": f"Bearer {access_token}"})
    csrf_resp = session.get(f"{SUPERSET_URL}/api/v1/security/csrf_token/")
    if csrf_resp.status_code != 200 or not csrf_resp.json().get("result"):
        print(f"Failed to obtain Superset CSRF token: {csrf_resp.status_code}")
        return None
    session.headers.update({
        "X-CSRFToken": csrf_resp.json()["result"],
        "Referer": SUPERSET_URL,
    })
    return session


def find_chart(session, name):
    resp = session.get(f"{SUPERSET_URL}/api/v1/chart/")
    if resp.status_code != 200:
        return None
    return next((chart["id"] for chart in resp.json().get("result", [])
                 if chart.get("slice_name") == name), None)

def create_database_connection(session):
    """Create Trino database connection"""
    print("Creating Trino database connection...")
    
    database_data = {
        "database_name": "Trino Iceberg",
        "sqlalchemy_uri": "trino://admin@trino:8080/iceberg",
        "expose_in_sqllab": True,
        "allow_ctas": True,
        "allow_cvas": True,
        "allow_dml": True,
        "allow_run_async": True
    }
    
    resp = session.post(f"{SUPERSET_URL}/api/v1/database/", json=database_data)
    if resp.status_code == 201:
        db_id = resp.json()["id"]
        print(f"Database connection created successfully with ID: {db_id}")
        return db_id
    elif resp.status_code == 422:
        # Database might already exist, try to find it
        resp = session.get(f"{SUPERSET_URL}/api/v1/database/")
        if resp.status_code == 200:
            databases = resp.json()["result"]
            for db in databases:
                if db["database_name"] == "Trino Iceberg":
                    print(f"Found existing Trino database with ID: {db['id']}")
                    return db["id"]
    
    print(f"Failed to create database connection: {resp.status_code} - {resp.text}")
    return None

def create_dataset(session, database_id):
    """Create dataset for sales table"""
    print("Creating sales dataset...")
    
    dataset_data = {
        "database": database_id,
        "schema": "demo",
        "table_name": "sales"
    }
    
    resp = session.post(f"{SUPERSET_URL}/api/v1/dataset/", json=dataset_data)
    if resp.status_code == 201:
        dataset_id = resp.json()["id"]
        print(f"Sales dataset created successfully with ID: {dataset_id}")
        return dataset_id
    elif resp.status_code == 422:
        # Dataset might already exist, try to find it
        resp = session.get(f"{SUPERSET_URL}/api/v1/dataset/")
        if resp.status_code == 200:
            datasets = resp.json()["result"]
            for ds in datasets:
                db_ref = ds.get("database")
                ds_database_id = db_ref.get("id") if isinstance(db_ref, dict) else db_ref
                if ds["table_name"] == "sales" and ds.get("schema") == "demo" and ds_database_id == database_id:
                    print(f"Found existing sales dataset with ID: {ds['id']}")
                    return ds["id"]
    
    print(f"Failed to create dataset: {resp.status_code} - {resp.text}")
    return None

def create_chart(session, dataset_id):
    """Create sales count chart"""
    existing = find_chart(session, "Sales Count by Product")
    if existing:
        print(f"Using existing Sales Count by Product chart (ID {existing})")
        return existing
    print("Creating sales count chart...")
    
    chart_data = {
        "slice_name": "Sales Count by Product",
        "viz_type": "pie",
        "datasource_id": dataset_id,
        "datasource_type": "table",
        "params": json.dumps({
            "groupby": ["product_id"],
            "metric": "count",
            "viz_type": "pie",
            "row_limit": 10000
        })
    }
    
    resp = session.post(f"{SUPERSET_URL}/api/v1/chart/", json=chart_data)
    if resp.status_code == 201:
        chart_id = resp.json()["id"]
        print(f"Chart created successfully with ID: {chart_id}")
        return chart_id
    
    print(f"Failed to create chart: {resp.status_code} - {resp.text}")
    return None

def create_sales_volume_chart(session, dataset_id):
    """Create sales volume chart"""
    existing = find_chart(session, "Total Sales Volume")
    if existing:
        print(f"Using existing Total Sales Volume chart (ID {existing})")
        return existing
    print("Creating sales volume chart...")
    
    chart_data = {
        "slice_name": "Total Sales Volume",
        "viz_type": "big_number_total",
        "datasource_id": dataset_id,
        "datasource_type": "table",
        "params": json.dumps({
            "metric": "sum__qty",
            "viz_type": "big_number_total"
        })
    }
    
    resp = session.post(f"{SUPERSET_URL}/api/v1/chart/", json=chart_data)
    if resp.status_code == 201:
        chart_id = resp.json()["id"]
        print(f"Sales volume chart created successfully with ID: {chart_id}")
        return chart_id
    
    print(f"Failed to create sales volume chart: {resp.status_code} - {resp.text}")
    return None

def create_revenue_chart(session, dataset_id):
    """Create total revenue chart"""
    print("Creating or updating total revenue chart...")

    params = {
        "metric": {
            "expressionType": "SQL",
            "sqlExpression": "SUM(qty * price)",
            "label": "Revenue",
            "optionName": "metric_revenue",
        },
        "viz_type": "big_number_total",
    }
    chart_data = {
        "slice_name": "Total Revenue",
        "viz_type": "big_number_total",
        "datasource_id": dataset_id,
        "datasource_type": "table",
        "params": json.dumps(params),
    }
    existing = find_chart(session, "Total Revenue")
    if existing:
        resp = session.put(f"{SUPERSET_URL}/api/v1/chart/{existing}", json=chart_data)
        if resp.status_code in (200, 201):
            print(f"Updated existing Total Revenue chart (ID {existing})")
            return existing
        print(f"Failed to update revenue chart: {resp.status_code} - {resp.text}")
        return None
    
    resp = session.post(f"{SUPERSET_URL}/api/v1/chart/", json=chart_data)
    if resp.status_code == 201:
        chart_id = resp.json()["id"]
        print(f"Revenue chart created successfully with ID: {chart_id}")
        return chart_id
    
    print(f"Failed to create revenue chart: {resp.status_code} - {resp.text}")
    return None


def create_daily_revenue_chart(session, dataset_id):
    """Create/update a revenue trend grouped by the sale timestamp."""
    name = "Daily Revenue Trend"
    params = {
        "viz_type": "echarts_timeseries_line",
        "granularity_sqla": "sale_ts",
        "time_grain_sqla": "P1D",
        "time_range": "No filter",
        "metrics": [{
            "expressionType": "SQL",
            "sqlExpression": "SUM(qty * price)",
            "label": "Revenue",
            "optionName": "metric_daily_revenue",
        }],
        "show_legend": True,
        "rich_tooltip": True,
        "row_limit": 10000,
    }
    data = {
        "slice_name": name,
        "viz_type": params["viz_type"],
        "datasource_id": dataset_id,
        "datasource_type": "table",
        "params": json.dumps(params),
    }
    existing = find_chart(session, name)
    if existing:
        resp = session.put(f"{SUPERSET_URL}/api/v1/chart/{existing}", json=data)
        if resp.status_code in (200, 201):
            print(f"Updated existing {name} chart (ID {existing})")
            return existing
    else:
        resp = session.post(f"{SUPERSET_URL}/api/v1/chart/", json=data)
        if resp.status_code == 201:
            chart_id = resp.json()["id"]
            print(f"Created {name} chart (ID {chart_id})")
            return chart_id
    print(f"Failed to create/update {name}: {resp.status_code} - {resp.text}")
    return None

def create_dashboard(session, chart_ids):
    """Create dashboard with charts"""
    response = session.get(f"{SUPERSET_URL}/api/v1/dashboard/")
    existing_id = None
    if response.status_code == 200:
        for dashboard in response.json().get("result", []):
            if dashboard.get("slug") == "sales-analytics":
                existing_id = dashboard["id"]
                break
    print("Updating sales dashboard..." if existing_id else "Creating sales dashboard...")
    
    # Create position json for dashboard layout
    position_json = {
        "CHART-1": {
            "children": [],
            "id": "CHART-1",
            "meta": {"chartId": chart_ids[0], "width": 6, "height": 50},
            "type": "CHART"
        },
        "CHART-2": {
            "children": [],
            "id": "CHART-2", 
            "meta": {"chartId": chart_ids[1], "width": 3, "height": 50},
            "type": "CHART"
        },
        "CHART-3": {
            "children": [],
            "id": "CHART-3",
            "meta": {"chartId": chart_ids[2], "width": 3, "height": 50},
            "type": "CHART"
        },
        "CHART-4": {
            "children": [],
            "id": "CHART-4",
            "meta": {"chartId": chart_ids[3], "width": 12, "height": 50},
            "type": "CHART"
        },
        "GRID_ID": {
            "children": ["ROW-1", "ROW-2"],
            "id": "GRID_ID",
            "type": "GRID"
        },
        "HEADER_ID": {
            "id": "HEADER_ID",
            "meta": {"text": "Sales Analytics Dashboard"},
            "type": "HEADER"
        },
        "ROOT_ID": {
            "children": ["GRID_ID"],
            "id": "ROOT_ID",
            "type": "ROOT"
        },
        "ROW-1": {
            "children": ["CHART-2", "CHART-3", "CHART-1"],
            "id": "ROW-1",
            "meta": {"background": "BACKGROUND_TRANSPARENT"},
            "type": "ROW"
        },
        "ROW-2": {
            "children": ["CHART-4"],
            "id": "ROW-2",
            "meta": {"background": "BACKGROUND_TRANSPARENT"},
            "type": "ROW"
        }
    }
    
    dashboard_data = {
        "dashboard_title": "Sales Analytics Dashboard",
        "slug": "sales-analytics",
        "owners": [1],
        "position_json": json.dumps(position_json),
    }
    
    if existing_id:
        resp = session.put(f"{SUPERSET_URL}/api/v1/dashboard/{existing_id}", json=dashboard_data)
    else:
        resp = session.post(f"{SUPERSET_URL}/api/v1/dashboard/", json=dashboard_data)
    if resp.status_code == 201:
        dashboard_id = resp.json()["id"]
        print(f"Dashboard created successfully with ID: {dashboard_id}")
        print(f"Access the dashboard at: {SUPERSET_URL}/superset/dashboard/{dashboard_id}/")
        return dashboard_id
    if resp.status_code == 200 and existing_id:
        print(f"Updated existing dashboard (ID {existing_id})")
        return existing_id
    
    print(f"Failed to create dashboard: {resp.status_code} - {resp.text}")
    return None

def main():
    print("Configuring Superset for Trino/Iceberg integration...")
    
    # Wait for Superset to be ready
    print("Waiting for Superset to be ready...")
    for i in range(30):
        try:
            resp = requests.get(f"{SUPERSET_URL}/health")
            if resp.status_code == 200:
                break
        except:
            pass
        time.sleep(2)
    else:
        print("Superset is not ready after 60 seconds")
        sys.exit(1)
    
    # Login
    session = login()
    if not session:
        print("Failed to login to Superset")
        sys.exit(1)
    
    # Create database connection
    database_id = create_database_connection(session)
    if not database_id:
        print("Failed to create database connection")
        sys.exit(1)
    
    # Create dataset
    dataset_id = create_dataset(session, database_id)
    if not dataset_id:
        print("Failed to create dataset")
        sys.exit(1)
    
    # Create charts
    chart_ids = []
    
    chart_id = create_chart(session, dataset_id)
    if chart_id:
        chart_ids.append(chart_id)
    
    volume_chart_id = create_sales_volume_chart(session, dataset_id)
    if volume_chart_id:
        chart_ids.append(volume_chart_id)
        
    revenue_chart_id = create_revenue_chart(session, dataset_id)
    if revenue_chart_id:
        chart_ids.append(revenue_chart_id)

    daily_revenue_chart_id = create_daily_revenue_chart(session, dataset_id)
    if daily_revenue_chart_id:
        chart_ids.append(daily_revenue_chart_id)
    
    if len(chart_ids) != 4:
        print("Expected four dashboard charts; setup did not complete")
        sys.exit(1)
        sys.exit(1)
    
    # Create dashboard
    dashboard_id = create_dashboard(session, chart_ids)
    if not dashboard_id:
        print("Failed to create dashboard")
        sys.exit(1)

    try:
        subprocess.run([
            "docker", "compose", "exec", "-T", "superset", "python",
            "/superset/link_dashboard_charts.py", str(dashboard_id),
            ",".join(str(chart_id) for chart_id in chart_ids),
        ], check=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"Failed to link charts to dashboard: {exc}")
        sys.exit(1)
    
    print("\n✅ Setup completed successfully!")
    print(f"🌐 Superset: {SUPERSET_URL}")
    print(f"👤 Login user: {USERNAME}")
    print(f"📊 Dashboard: {SUPERSET_URL}/superset/dashboard/{dashboard_id}/")

if __name__ == "__main__":
    main()
