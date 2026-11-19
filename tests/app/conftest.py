"""Fixtures for the web application tests. Run with scripts/test_app.sh (sets up the database and env)."""

import os
import re

import psycopg
import pytest
from fastapi.testclient import TestClient

from real_estate_erp.security import hash_password

ADMIN_EMAIL = os.environ["ERP_TEST_ADMIN_EMAIL"]
ADMIN_PASSWORD = os.environ["ERP_TEST_ADMIN_PASSWORD"]
ACCOUNTANT_EMAIL = "accountant@office.local"
ACCOUNTANT_PASSWORD = "accountant-" + os.urandom(12).hex()


def csrf_from(html: str) -> str:
    match = re.search(r'name="csrf" value="([^"]+)"', html)
    assert match, "no CSRF field on the page"
    return match.group(1)


def sign_in(client: TestClient, email: str, password: str):
    page = client.get("/login")
    return client.post("/login", data={"email": email, "password": password, "csrf": csrf_from(page.text)},
                       follow_redirects=False)


@pytest.fixture(scope="session")
def owner_db():
    with psycopg.connect(os.environ["ERP_OWNER_DATABASE_URL"], autocommit=True) as conn:
        yield conn


@pytest.fixture(scope="session")
def app():
    from real_estate_erp.web import app as web_app
    return web_app


@pytest.fixture
def client(app):
    with TestClient(app, base_url="https://testserver") as c:
        yield c


@pytest.fixture
def admin(client):
    response = sign_in(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    assert response.status_code == 303, response.text
    return client


@pytest.fixture(scope="session")
def accountant(owner_db):
    """A non-admin employee with a password, created by Admin (one employee per transaction)."""
    admin_id = owner_db.execute("SELECT id FROM app_users WHERE email = %s", [ADMIN_EMAIL]).fetchone()[0]
    with owner_db.transaction():
        owner_db.execute("SELECT erp_act_as_internal(%s)", [admin_id])
        accountant_id = owner_db.execute(
            "INSERT INTO app_users (full_name, email, role) VALUES ('Test Accountant', %s, 'accountant') RETURNING id",
            [ACCOUNTANT_EMAIL]).fetchone()[0]
    with owner_db.transaction():
        owner_db.execute("SELECT erp_set_password(%s, %s)", [accountant_id, hash_password(ACCOUNTANT_PASSWORD)])
    return accountant_id
