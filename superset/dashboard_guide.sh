#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Missing .env; copy .env.example to .env first." >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source .env
set +a
python3 superset/setup_dashboard.py
