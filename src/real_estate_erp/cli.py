"""Command line: create the administrator account, and run the development server.

    real-estate-erp create-admin [--email admin@office.local]   (prompts for the password)
    real-estate-erp serve [--port 8000]
"""

import argparse
import getpass
import sys

import psycopg

from . import password_policy
from .password_policy import MAX_PASSWORD_LENGTH, MIN_PASSWORD_LENGTH
from .security import hash_password

ADMIN_DISPLAY_NAME = "Admin"


def create_admin(owner_database_url: str, email: str, password: str) -> str:
    """Creates the first administrator ("Admin") and stores the Argon2id hash of the password.

    Runs as the database owner: erp_bootstrap_admin only works while no admin exists. The password is
    never stored or logged; only its hash reaches the database.
    """
    password_policy.check(password, email)          # raises PasswordRejected (a ValueError) with the reasons
    password_hash = hash_password(password)
    with psycopg.connect(owner_database_url) as conn:
        # Two transactions: one employee per transaction (the system user creates the admin, then the
        # admin's own credentials are stored as the admin).
        with conn.transaction():
            admin_id = conn.execute(
                "SELECT erp_bootstrap_admin(%s, %s)", [ADMIN_DISPLAY_NAME, email.strip().lower()]
            ).fetchone()[0]
        with conn.transaction():
            conn.execute("SELECT erp_set_password(%s, %s)", [admin_id, password_hash])
    return str(admin_id)


def _create_admin_command(args) -> int:
    from .config import Settings

    settings = Settings()
    if not settings.owner_database_url:
        print("ERP_OWNER_DATABASE_URL is not set (see .env).", file=sys.stderr)
        return 2
    print(f"Creating the administrator account '{ADMIN_DISPLAY_NAME}' <{args.email}>.")
    print(f"Password policy: {MIN_PASSWORD_LENGTH}-{MAX_PASSWORD_LENGTH} characters; spaces, Arabic and any symbols "
          "are allowed. Long passphrases are best. Common or breached passwords, simple sequences and "
          "passwords based on CAPNOVA or your email are rejected.")
    password = getpass.getpass("Choose a password: ")
    if password != getpass.getpass("Repeat the password: "):
        print("The passwords do not match.", file=sys.stderr)
        return 1
    try:
        admin_id = create_admin(settings.owner_database_url, args.email, password)
    except (ValueError, psycopg.Error) as exc:
        print(f"Could not create the administrator: {exc}", file=sys.stderr)
        return 1
    print(f"Administrator created ({admin_id}). Sign in with {args.email}.")
    return 0


def _serve_command(args) -> int:
    import uvicorn

    uvicorn.run("real_estate_erp.web:app", host=args.host, port=args.port)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="real-estate-erp")
    commands = parser.add_subparsers(dest="command", required=True)
    admin = commands.add_parser("create-admin", help="create the administrator account (prompts for the password)")
    admin.add_argument("--email", default="admin@office.local")
    admin.set_defaults(handler=_create_admin_command)
    serve = commands.add_parser("serve", help="run the development server")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8000)
    serve.set_defaults(handler=_serve_command)
    args = parser.parse_args(argv)
    return args.handler(args)
