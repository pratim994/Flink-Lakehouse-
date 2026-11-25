#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
[[ -f .env ]] || { echo "Missing .env; copy .env.example to .env and edit credentials." >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source .env
set +a
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER is required}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD is required}"
docker compose exec -T jobmanager curl -fsS http://localhost:8081/overview >/dev/null || {
  echo "Flink JobManager is not ready; start the stack and check 'docker compose ps'." >&2; exit 1;
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
render_sql() {
  python3 - "$1" "$2" <<'PY'
import os, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
for key in ("MYSQL_ROOT_PASSWORD", "MINIO_ROOT_USER", "MINIO_ROOT_PASSWORD"):
    value = os.environ[key].replace("'", "''")
    source = source.replace("${" + key + "}", value)
pathlib.Path(sys.argv[2]).write_text(source)
PY
}
run_sql() {
  local file="$1" target="/tmp/$(basename "$1")" log="$tmpdir/$(basename "$1").log"
  docker cp "$file" "$(docker compose ps -q jobmanager):$target" >/dev/null
  local init_target="/tmp/catalog.sql"
  docker cp "$tmpdir/catalog.sql" "$(docker compose ps -q jobmanager):$init_target" >/dev/null
  if ! docker compose exec -T jobmanager /opt/flink/bin/sql-client.sh -i "$init_target" -f "$target" >"$log" 2>&1; then
    python3 - "$log" <<'PY'
import os, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
for key in sorted(("MYSQL_ROOT_PASSWORD", "MINIO_ROOT_USER", "MINIO_ROOT_PASSWORD"), key=lambda k: len(os.environ[k]), reverse=True):
    text = text.replace(os.environ[key], "[REDACTED]")
print(text, end="")
PY
    docker compose exec -T jobmanager rm -f "$target" "$init_target" >/dev/null || true
    return 1
  fi
  if ! python3 - "$log" <<'PY'
import os, pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
for key in sorted(("MYSQL_ROOT_PASSWORD", "MINIO_ROOT_USER", "MINIO_ROOT_PASSWORD"), key=lambda k: len(os.environ[k]), reverse=True):
    text = text.replace(os.environ[key], "[REDACTED]")
print(text, end="")
if re.search(r"\[ERROR\]|Could not execute SQL statement|Exception", text):
    raise SystemExit(1)
PY
  then
    docker compose exec -T jobmanager rm -f "$target" "$init_target" >/dev/null || true
    return 1
  fi
  docker compose exec -T jobmanager rm -f "$target" "$init_target" >/dev/null
}

echo "Preparing the Iceberg catalog in each isolated SQL Client session..."
render_sql jobs/catalog.sql "$tmpdir/catalog.sql"
echo "Creating Iceberg tables (no streaming writers)..."
render_sql jobs/job.sql "$tmpdir/bootstrap.sql"
run_sql "$tmpdir/bootstrap.sql"
for job in products_streaming.sql sales_streaming.sql; do
  if [[ "$job" == products_streaming.sql ]]; then name=cdc-products-to-iceberg; else name=cdc-sales-to-iceberg; fi
  if docker compose exec -T jobmanager curl -fsS http://localhost:8081/jobs/overview \
    | python3 -c 'import json,sys; name=sys.argv[1]; jobs=json.load(sys.stdin)["jobs"]; sys.exit(0 if any(j["name"]==name and j["state"] not in ("FAILED","CANCELED","FINISHED") for j in jobs) else 1)' "$name"; then
    echo "Skipping $name: an active job with this name already exists."
    continue
  fi
  echo "Submitting $name..."
  render_sql "jobs/$job" "$tmpdir/$job"
  run_sql "$tmpdir/$job"
done
echo "Submitted exactly two named streaming jobs. Inspect with: docker compose exec jobmanager /opt/flink/bin/flink list -r"
