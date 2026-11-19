#!/usr/bin/env bash
# Loads real_estate_erp_schema.sql into a throwaway PostgreSQL container and runs tests/sql/schema_test.sql.
# Requires Docker. Override the image with POSTGRES_IMAGE (PostgreSQL 15+).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${POSTGRES_IMAGE:-postgres:16}"
NAME="erp-schema-test-$$"

docker run --rm -d --name "$NAME" -e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

# Wait for the real server (the init-time server does not listen on TCP).
for _ in $(seq 60); do
  docker exec "$NAME" psql -h 127.0.0.1 -U postgres -qtAc 'SELECT 1' >/dev/null 2>&1 && break
  sleep 1
done

psql_run() { docker exec -i "$NAME" psql -h 127.0.0.1 -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

echo "== Loading schema"
psql_run < real_estate_erp_schema.sql
echo "== Running tests"
psql_run < tests/sql/schema_test.sql
