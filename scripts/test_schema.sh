#!/usr/bin/env bash
# Loads real_estate_erp_schema.sql into a throwaway PostgreSQL container and runs:
#   1. tests/sql/schema_test.sql in database "postgres";
#   2. the development seed (db/seeds/dev_jeddah_lands.sql) and tests/sql/seed_test.sql in a separate,
#      empty database "seed_test": once without the development flag (must do nothing), then twice with it.
# Requires Docker. Override the image with POSTGRES_IMAGE (PostgreSQL 15+).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${POSTGRES_IMAGE:-postgres:16}"
NAME="erp-schema-test-$$"
SEED=db/seeds/dev_jeddah_lands.sql

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
echo "== Running schema tests"
psql_run < tests/sql/schema_test.sql

echo "== Seed tests (separate database seed_test)"
psql_run -c 'CREATE DATABASE seed_test'
psql_run -d seed_test < real_estate_erp_schema.sql
echo "-- seed run without the development flag (expected: refusal, nothing inserted)"
psql_run -d seed_test < "$SEED"
psql_run -d seed_test -c 'CREATE TABLE seed_guard_check AS SELECT count(*) AS lands_after_refused_run FROM lands'
echo "-- seed run 1 (development)"
psql_run -d seed_test -v seed_env=development < "$SEED" >/dev/null
psql_run -d seed_test -c 'CREATE TABLE seed_snapshot AS SELECT * FROM lands'
echo "-- seed run 2 (development, must change nothing)"
psql_run -d seed_test -v seed_env=development < "$SEED"
psql_run -d seed_test < tests/sql/seed_test.sql
