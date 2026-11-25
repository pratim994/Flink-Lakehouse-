#!/bin/bash

set -euo pipefail

# Install the SQLAlchemy Trino dialect. Pin the driver to make restarts repeatable.
pip install --no-cache-dir 'trino[sqlalchemy]==0.333.0' 'PyHive[trino]==0.7.0' 'google-auth==2.47.0'

# Initialize Superset database
superset db upgrade

# Create admin user
ADMIN_USERNAME="${SUPERSET_ADMIN_USERNAME:-admin}"
if ! superset fab list-users 2>/dev/null | grep -Fq "$ADMIN_USERNAME"; then
  superset fab create-admin \
      --username "$ADMIN_USERNAME" \
      --firstname "${ADMIN_FIRST_NAME:-Admin}" \
      --lastname "${ADMIN_LAST_NAME:-User}" \
      --email "${ADMIN_EMAIL:-admin@example.com}" \
      --password "${SUPERSET_ADMIN_PASSWORD:?SUPERSET_ADMIN_PASSWORD is required}"
fi

# Initialize Superset roles and permissions
superset init

# Start Superset
exec gunicorn "superset.app:create_app()"
