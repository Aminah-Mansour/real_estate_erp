#!/usr/bin/env bash
# Sets up the LOCAL DEVELOPMENT environment (development data only):
#   1. creates .env with random passwords and secret key (first run only; never committed)
#   2. starts PostgreSQL 16 in Docker (listening on 127.0.0.1 only)
#   3. installs the schema (Alembic baseline), the database logins and the Jeddah development seed
#   4. creates the administrator "Admin" - you choose the password at the prompt
# Then run:  uv run real-estate-erp serve   and open http://127.0.0.1:8000
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  rand() { python3 -c 'import secrets; print(secrets.token_hex(24))'; }
  pg_pw=$(rand); app_pw=$(rand); auth_pw=$(rand); secret=$(rand)
  umask 077
  cat > .env <<EOF
ERP_ENV=development
ERP_DEV_DB_PORT=5433
ERP_DEV_POSTGRES_PASSWORD=$pg_pw
ERP_DEV_APP_DB_PASSWORD=$app_pw
ERP_DEV_AUTH_DB_PASSWORD=$auth_pw
ERP_OWNER_DATABASE_URL=postgresql://postgres:$pg_pw@127.0.0.1:5433/erp
ERP_APP_DATABASE_URL=postgresql://erp_app_login:$app_pw@127.0.0.1:5433/erp
ERP_AUTH_DATABASE_URL=postgresql://erp_auth_login:$auth_pw@127.0.0.1:5433/erp
ERP_SECRET_KEY=$secret
EOF
  echo "Created .env with random development secrets (permissions 600)."
fi
set -a; . ./.env; set +a

echo "== Starting the development database"
docker compose up -d --wait db

psql_owner() { docker compose exec -T db psql -U postgres -d erp -X -q -v ON_ERROR_STOP=1 "$@"; }

echo "== Installing the schema (Alembic)"
uv run alembic upgrade head

echo "== Database logins for the application and the login service"
psql_owner -v app_pw="$ERP_DEV_APP_DB_PASSWORD" -v auth_pw="$ERP_DEV_AUTH_DB_PASSWORD" < db/dev_logins.sql

echo "== Jeddah development seed"
psql_owner -v seed_env=development < db/seeds/dev_jeddah_lands.sql

if [ "$(psql_owner -tAc "SELECT count(*) FROM app_users WHERE role = 'admin' AND NOT is_system")" = "0" ]; then
  echo "== Administrator account"
  uv run real-estate-erp create-admin
else
  echo "== Administrator account already exists"
fi

echo
echo "Ready. Start the app with:  uv run real-estate-erp serve   then open http://127.0.0.1:8000"
