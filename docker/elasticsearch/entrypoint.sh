#!/bin/bash
set -e

# Populate the ES keystore with MinIO credentials at container startup.
# Credentials are passed via MINIO_ACCESS_KEY / MINIO_SECRET_KEY env vars.
# The S3 client name must match ES_S3_CLIENT_NAME (default: minio).

CLIENT="${ES_S3_CLIENT_NAME:-minio}"

if [ -n "${MINIO_ACCESS_KEY}" ]; then
    echo -n "${MINIO_ACCESS_KEY}" | \
        elasticsearch-keystore add --stdin --force \
        "s3.client.${CLIENT}.access_key" 2>/dev/null
fi

if [ -n "${MINIO_SECRET_KEY}" ]; then
    echo -n "${MINIO_SECRET_KEY}" | \
        elasticsearch-keystore add --stdin --force \
        "s3.client.${CLIENT}.secret_key" 2>/dev/null
fi

# Hand off to the official ES entrypoint
exec /usr/local/bin/docker-entrypoint.sh "$@"
