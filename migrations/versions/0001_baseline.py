"""Baseline: installs real_estate_erp_schema.sql (the complete schema, tested by scripts/test_schema.sh).

Revision ID: 0001_baseline
Revises:
"""

from pathlib import Path

from alembic import op

revision = "0001_baseline"
down_revision = None
branch_labels = None
depends_on = None

SCHEMA_FILE = Path(__file__).resolve().parents[2] / "real_estate_erp_schema.sql"


def upgrade() -> None:
    sql = SCHEMA_FILE.read_text(encoding="utf-8")
    # Executed as-is by the driver (no parameter substitution), exactly like psql loads it.
    with op.get_bind().connection.dbapi_connection.cursor() as cursor:
        cursor.execute(sql)


def downgrade() -> None:
    raise RuntimeError("The baseline cannot be downgraded: financial records are permanent.")
