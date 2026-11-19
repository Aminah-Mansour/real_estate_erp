"""Alembic environment. Migrations run as the schema owner (ERP_OWNER_DATABASE_URL).

The version table lives in its own schema (erp_migrations) so it stays outside the protected
public schema.
"""

import os

from alembic import context
from sqlalchemy import create_engine

VERSION_SCHEMA = "erp_migrations"


def _url() -> str:
    url = os.environ.get("ERP_OWNER_DATABASE_URL")
    if not url:
        raise RuntimeError("Set ERP_OWNER_DATABASE_URL to run migrations (see .env).")
    return url.replace("postgresql://", "postgresql+psycopg://", 1)


def run_migrations_online() -> None:
    engine = create_engine(_url())
    with engine.connect() as connection:
        connection.exec_driver_sql(f"CREATE SCHEMA IF NOT EXISTS {VERSION_SCHEMA}")
        connection.commit()
        context.configure(connection=connection, target_metadata=None, version_table_schema=VERSION_SCHEMA)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    raise RuntimeError("Offline migrations are not supported; run against a database.")
run_migrations_online()
