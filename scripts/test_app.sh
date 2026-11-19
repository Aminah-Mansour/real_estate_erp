#!/usr/bin/env bash
# Runs the web application tests (tests/app) against a throwaway PostgreSQL container:
# Alembic baseline, database logins, Jeddah development seed, an administrator with a random password,
# then pytest. All secrets are random per run and never written to disk. Requires Docker.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${POSTGRES_IMAGE:-postgres:16}"
NAME="erp-app-test-$$"
rand() { python3 -c 'import secrets; print(secrets.token_hex(24))'; }
pg_pw=$(rand); app_pw=$(rand); auth_pw=$(rand)

docker run --rm -d --name "$NAME" -e POSTGRES_PASSWORD="$pg_pw" -e POSTGRES_DB=erp_test -p 127.0.0.1::5432 "$IMAGE" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
port=$(docker port "$NAME" 5432/tcp | head -1 | sed 's/.*://')
for _ in $(seq 60); do
  docker exec "$NAME" psql -h 127.0.0.1 -U postgres -d erp_test -qtAc 'SELECT 1' >/dev/null 2>&1 && break
  sleep 1
done
psql_owner() { docker exec -i "$NAME" psql -U postgres -d erp_test -X -q -v ON_ERROR_STOP=1 "$@"; }

export ERP_ENV=development
export ERP_OWNER_DATABASE_URL="postgresql://postgres:$pg_pw@127.0.0.1:$port/erp_test"
export ERP_APP_DATABASE_URL="postgresql://erp_app_login:$app_pw@127.0.0.1:$port/erp_test"
export ERP_AUTH_DATABASE_URL="postgresql://erp_auth_login:$auth_pw@127.0.0.1:$port/erp_test"
export ERP_SECRET_KEY="$(rand)"
export ERP_TEST_ADMIN_EMAIL="admin@office.local"
export ERP_TEST_ADMIN_PASSWORD="$(rand)"

echo "== Schema (Alembic baseline)"
uv run alembic upgrade head
echo "== Database logins"
psql_owner -v app_pw="$app_pw" -v auth_pw="$auth_pw" < db/dev_logins.sql
echo "== Jeddah development seed"
psql_owner -v seed_env=development < db/seeds/dev_jeddah_lands.sql >/dev/null
echo "== Administrator"
uv run python -c 'import os; from real_estate_erp.cli import create_admin; create_admin(os.environ["ERP_OWNER_DATABASE_URL"], os.environ["ERP_TEST_ADMIN_EMAIL"], os.environ["ERP_TEST_ADMIN_PASSWORD"])'
echo "== Web application tests"
uv run pytest tests/app "$@"
