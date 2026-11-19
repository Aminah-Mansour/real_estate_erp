"""Database access.

Every page request runs in a transaction that first names the signed-in employee with
erp_act_as(session token) and is then switched to READ ONLY, so pages can never change data.
Login and logout are the only writes, and they go through the database's own functions.
"""

from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass

import psycopg
from psycopg.rows import dict_row

from .config import Settings
from .security import burn_verification_time, new_session_token, verify_password


class SessionInvalid(Exception):
    """The session token is missing, unknown, expired, revoked, or its employee is disabled."""


@contextmanager
def acting_transaction(settings: Settings, session_token: str | None, *, read_only: bool = True) -> Iterator[psycopg.Connection]:
    if not session_token:
        raise SessionInvalid()
    conn = psycopg.connect(settings.app_database_url, row_factory=dict_row)
    try:
        with conn.transaction():
            try:
                conn.execute("SELECT erp_act_as(%s)", [session_token])
            except psycopg.errors.InsufficientPrivilege as exc:
                raise SessionInvalid() from exc
            if read_only:
                conn.execute("SET TRANSACTION READ ONLY")
            yield conn
    finally:
        conn.close()


@dataclass
class LoginResult:
    ok: bool
    session_token: str | None = None
    reason: str | None = None  # "invalid" or "not_admin"


def authenticate(settings: Settings, email: str, password: str) -> LoginResult:
    """Checks an employee's password as the login service (erp_auth) and opens a session.

    This MVP admits administrators only. Five consecutive failures lock the account for 15 minutes
    (recorded by erp_record_login_result). Unknown accounts, wrong passwords and locked accounts all get
    the same answer, after the same amount of work.
    """
    email = email.strip().lower()
    with psycopg.connect(settings.auth_database_url, row_factory=dict_row) as conn:
        with conn.transaction():
            row = conn.execute(
                """SELECT u.id, u.role, u.status, c.password_hash,
                          coalesce(c.locked_until > now(), false) AS locked
                     FROM app_users u JOIN user_credentials c ON c.user_id = u.id
                    WHERE u.email = %s AND NOT u.is_system""",
                [email],
            ).fetchone()

        if row is None or row["status"] != "active":
            burn_verification_time(password)
            return LoginResult(ok=False, reason="invalid")
        if row["locked"]:
            burn_verification_time(password)
            return LoginResult(ok=False, reason="invalid")
        if not verify_password(row["password_hash"], password):
            with conn.transaction():
                conn.execute("SELECT erp_record_login_result(%s, false)", [row["id"]])
            return LoginResult(ok=False, reason="invalid")
        if row["role"] != "admin":
            return LoginResult(ok=False, reason="not_admin")

        token = new_session_token()
        with conn.transaction():
            conn.execute(
                "SELECT erp_open_session(%s, %s, make_interval(hours => %s))",
                [row["id"], token, settings.session_hours],
            )
            conn.execute("SELECT erp_record_login_result(%s, true)", [row["id"]])
        return LoginResult(ok=True, session_token=token)


def end_session(settings: Settings, session_token: str | None) -> None:
    """Logs the session out (revokes it). Silently ignores a session that is already invalid."""
    try:
        with acting_transaction(settings, session_token, read_only=False) as conn:
            conn.execute("SELECT erp_end_session()")
    except SessionInvalid:
        pass
