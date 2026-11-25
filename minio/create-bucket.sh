#!/bin/sh
set -e
# Wait for MinIO to be ready
until mc alias set local http://minio:9000 "${MINIO_ROOT_USER:-local-minio}" "${MINIO_ROOT_PASSWORD:-local-minio-password-change-me}" 2>/dev/null; do
  echo "Waiting for MinIO..."
  sleep 2
done
mc mb -p local/iceberg || true
mc mb -p local/iceberg/warehouse || true
echo "MinIO buckets ready."
