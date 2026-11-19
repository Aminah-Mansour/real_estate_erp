"""Read-only queries used by the pages (run inside an acting, read-only transaction)."""

from uuid import UUID

import psycopg

LAND_COLUMNS = """
    p.land_id, p.city, p.city_name_en, p.plan_number, p.land_number, p.status,
    p.purchase_price, p.purchase_tax, p.dalalah, p.total_acquisition_cost, p.purchase_recorded,
    l.area_sqm, l.street_width_m, l.street, l.created_at
"""


def current_employee(conn: psycopg.Connection) -> dict:
    return conn.execute(
        "SELECT id, full_name, role, email FROM app_users WHERE id = erp_acting_user_id()"
    ).fetchone()


def lands(conn: psycopg.Connection) -> list[dict]:
    return conn.execute(
        f"""SELECT {LAND_COLUMNS}
              FROM land_acquisition_preview p JOIN lands l ON l.id = p.land_id
             WHERE l.is_active
             ORDER BY p.city, p.plan_number, p.land_number"""
    ).fetchall()


def land(conn: psycopg.Connection, land_id: UUID) -> dict | None:
    return conn.execute(
        f"""SELECT {LAND_COLUMNS}
              FROM land_acquisition_preview p JOIN lands l ON l.id = p.land_id
             WHERE p.land_id = %s AND l.is_active""",
        [land_id],
    ).fetchone()


def land_totals(conn: psycopg.Connection) -> dict:
    return conn.execute(
        """SELECT count(*) AS land_count,
                  coalesce(sum(p.purchase_price), 0) AS purchase_price,
                  coalesce(sum(p.purchase_tax), 0) AS purchase_tax,
                  coalesce(sum(p.dalalah), 0) AS dalalah,
                  coalesce(sum(p.total_acquisition_cost), 0) AS total_acquisition_cost,
                  coalesce(sum(l.area_sqm), 0) AS area_sqm
             FROM land_acquisition_preview p JOIN lands l ON l.id = p.land_id
            WHERE l.is_active"""
    ).fetchone()


def land_status_counts(conn: psycopg.Connection) -> list[dict]:
    return conn.execute(
        """SELECT status, count(*) AS n FROM lands
            WHERE parent_land_id IS NULL AND is_active
            GROUP BY status ORDER BY n DESC, status"""
    ).fetchall()


def module_counts(conn: psycopg.Connection) -> dict:
    return conn.execute(
        """SELECT (SELECT count(*) FROM investors WHERE is_active) AS investors,
                  (SELECT count(*) FROM portfolios WHERE is_active) AS portfolios,
                  (SELECT count(*) FROM deals WHERE is_active) AS deals,
                  (SELECT count(*) FROM ledger_accounts WHERE is_active) AS ledger_accounts,
                  (SELECT count(*) FROM journal_entries WHERE status = 'posted') AS journal_posted,
                  (SELECT count(*) FROM journal_entries WHERE status = 'draft') AS journal_draft,
                  (SELECT count(*) FROM land_purchases) AS land_purchases,
                  (SELECT count(*) FROM deal_sales WHERE status = 'completed') AS sales"""
    ).fetchone()


def recent_activity(conn: psycopg.Connection, limit: int = 6) -> list[dict]:
    return conn.execute(
        """SELECT a.action, a.entity_type, a.occurred_at, u.full_name AS actor
             FROM audit_events a LEFT JOIN app_users u ON u.id = a.actor_id
            ORDER BY a.occurred_at DESC
            LIMIT %s""",
        [limit],
    ).fetchall()
