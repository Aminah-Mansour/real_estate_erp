"""Web application tests: sign-in, sessions, languages, the Jeddah lands, read-only pages, security headers."""

import re
import uuid

import pytest

from .conftest import ACCOUNTANT_EMAIL, ACCOUNTANT_PASSWORD, ADMIN_EMAIL, ADMIN_PASSWORD, csrf_from, sign_in

PAGES = ["/", "/lands", "/investors", "/portfolios", "/accounting"]


def cookie_header(response, name):
    return next(h for h in response.headers.get_list("set-cookie") if h.startswith(name + "="))


def counts(owner_db):
    return owner_db.execute(
        """SELECT (SELECT count(*) FROM lands), (SELECT count(*) FROM investors), (SELECT count(*) FROM land_purchases),
                  (SELECT count(*) FROM journal_entries), (SELECT count(*) FROM capital_movements),
                  (SELECT count(*) FROM deal_sales), (SELECT count(*) FROM audit_events)""").fetchone()


# ---- sign-in -------------------------------------------------------------------------------------

def test_login_page_is_arabic_and_right_to_left_by_default(client):
    page = client.get("/login")
    assert page.status_code == 200
    assert '<html lang="ar" dir="rtl">' in page.text
    assert "تسجيل الدخول" in page.text and "نظام إدارة العقارات" in page.text


@pytest.mark.parametrize("path", PAGES)
def test_every_page_requires_sign_in(client, path):
    response = client.get(path, follow_redirects=False)
    assert response.status_code == 303 and response.headers["location"] == "/login"


def test_login_without_csrf_token_is_rejected(client):
    client.get("/login")
    response = client.post("/login", data={"email": ADMIN_EMAIL, "password": ADMIN_PASSWORD, "csrf": "forged"},
                           follow_redirects=False)
    assert response.status_code == 303 and response.headers["location"] == "/login?m=form"
    assert "erp_session" not in response.cookies


def test_wrong_password_is_refused_without_a_session(client):
    response = sign_in(client, ADMIN_EMAIL, "not-the-password")
    assert response.status_code == 401
    assert "غير صحيحة" in response.text
    assert "erp_session" not in response.cookies


def test_unknown_account_gets_the_same_answer(client):
    response = sign_in(client, "nobody@office.local", "whatever-password")
    assert response.status_code == 401 and "غير صحيحة" in response.text


def test_admin_signs_in_with_a_secure_session_cookie(client):
    response = sign_in(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    assert response.status_code == 303 and response.headers["location"] == "/"
    cookie = cookie_header(response, "erp_session").lower()
    assert "httponly" in cookie and "secure" in cookie and "samesite=strict" in cookie


def test_sign_in_is_audited_as_the_admin(client, owner_db):
    sign_in(client, ADMIN_EMAIL, ADMIN_PASSWORD)
    row = owner_db.execute(
        """SELECT u.full_name FROM audit_events a JOIN app_users u ON u.id = a.actor_id
            WHERE a.entity_type = 'user_sessions' AND a.action = 'session_open'
            ORDER BY a.occurred_at DESC LIMIT 1""").fetchone()
    assert row == ("Admin",)


def test_only_the_administrator_can_sign_in_to_this_version(client, accountant):
    response = sign_in(client, ACCOUNTANT_EMAIL, ACCOUNTANT_PASSWORD)
    assert response.status_code == 401 and "مخصص لحساب المسؤول فقط" in response.text
    assert "erp_session" not in response.cookies


def test_five_failed_attempts_lock_the_account(client, accountant, owner_db):
    for _ in range(5):
        assert sign_in(client, ACCOUNTANT_EMAIL, "wrong-password").status_code == 401
    locked = owner_db.execute("SELECT locked_until > now() FROM user_credentials WHERE user_id = %s", [accountant]).fetchone()[0]
    assert locked
    # Even the right password is refused while locked, with the generic message.
    response = sign_in(client, ACCOUNTANT_EMAIL, ACCOUNTANT_PASSWORD)
    assert response.status_code == 401 and "غير صحيحة" in response.text


def test_a_forged_session_cookie_is_refused(client):
    client.cookies.set("erp_session", "forged-session-token-0000000000000000000000")
    response = client.get("/", follow_redirects=False)
    assert response.status_code == 303 and response.headers["location"] == "/login?m=expired"


# ---- dashboard and lands ------------------------------------------------------------------------------

def test_dashboard_summary_cards(admin):
    page = admin.get("/")
    assert page.status_code == 200
    html = page.text
    assert "مرحبًا، Admin" in html
    for amount in ["4,400,000.00", "220,000.00", "110,000.00", "4,730,000.00"]:
        assert amount in html, amount
    assert "ر.س" in html
    assert "2,680" in html  # total area m²


def test_dashboard_lists_the_three_jeddah_lands(admin):
    html = admin.get("/").text
    for plan in ["99/أ", "29/ب", "87"]:
        assert f'<bdi dir="rtl">{plan}</bdi>' in html
    assert html.count('href="/lands/') == 3


def test_lands_page_shows_tax_dalalah_and_total_for_each_land(admin):
    html = admin.get("/lands").text
    for price, tax, dalalah, total in [("1,500,000.00", "75,000.00", "37,500.00", "1,612,500.00"),
                                       ("1,200,000.00", "60,000.00", "30,000.00", "1,290,000.00"),
                                       ("1,700,000.00", "85,000.00", "42,500.00", "1,827,500.00")]:
        for amount in (price, tax, dalalah, total):
            assert amount in html, amount
    assert html.count("جدة") >= 3
    assert "دلالة شراء الأرض" in html and "ضريبة الشراء" in html
    assert "قيد الدراسة" in html  # prospective


def test_land_detail_breakdown(admin, owner_db):
    land_id = owner_db.execute("SELECT id FROM lands WHERE plan_number = %s AND land_number = '1200'", ["99/أ"]).fetchone()[0]
    html = admin.get(f"/lands/{land_id}").text
    for amount in ["1,500,000.00", "75,000.00", "37,500.00", "1,612,500.00"]:
        assert amount in html
    assert "\u20665%\u2069 من سعر الشراء" in html and "\u20662.5%\u2069 من سعر الشراء" in html
    assert "عند الشراء فقط" in html


def test_unknown_land_is_404(admin):
    assert admin.get(f"/lands/{uuid.uuid4()}").status_code == 404


def test_arabic_numbers_use_western_digits(admin):
    html = admin.get("/lands").text
    assert not re.search("[٠-٩۰-۹]", html)


# ---- languages ------------------------------------------------------------------------------------

def test_switch_to_english(admin):
    response = admin.get("/lang/en?next=/lands", follow_redirects=False)
    assert response.status_code == 303 and response.headers["location"] == "/lands"
    html = admin.get("/lands").text
    assert '<html lang="en" dir="ltr">' in html
    assert "Land Purchase Brokerage Commission (Dalalah)" in html
    assert "SAR</span> <bdi class=\"num\">1,612,500.00" in html
    assert "Jeddah" in html and "Prospective" in html


def test_switch_back_to_arabic(admin):
    admin.get("/lang/en?next=/")
    admin.get("/lang/ar?next=/")
    assert '<html lang="ar" dir="rtl">' in admin.get("/").text


@pytest.mark.parametrize("target", ["//evil.example", "https://evil.example/", "/\\evil.example"])
def test_language_switch_cannot_redirect_off_site(client, target):
    response = client.get("/lang/en", params={"next": target}, follow_redirects=False)
    assert response.headers["location"] == "/"


# ---- navigation and read-only pages -----------------------------------------------------------------

def test_navigation_links_for_current_and_future_modules(admin):
    html = admin.get("/").text
    for href in ['href="/"', 'href="/lands"', 'href="/investors"', 'href="/portfolios"', 'href="/accounting"']:
        assert href in html
    for future in ["الصفقات", "توزيعات الأرباح", "التقارير", "الموظفون"]:
        assert future in html
    assert html.count("قريبًا") >= 4


@pytest.mark.parametrize("path", PAGES[2:])
def test_module_pages_render_read_only(admin, path):
    page = admin.get(path)
    assert page.status_code == 200 and "للعرض فقط" in page.text


def test_browsing_pages_changes_nothing(admin, owner_db):
    before = counts(owner_db)
    for path in PAGES + ["/lang/en?next=/", "/lands"]:
        admin.get(path)
    assert counts(owner_db) == before  # not even an audit record


def test_only_sign_in_and_sign_out_accept_posts(app):
    writes = sorted(p for r in app.routes for m in getattr(r, "methods", set()) if m not in ("GET", "HEAD")
                    for p in [r.path])
    assert writes == ["/login", "/logout"]


def test_page_transactions_are_read_only(owner_db, monkeypatch):
    """The database itself refuses a write inside a page transaction."""
    import psycopg
    from real_estate_erp import db
    from real_estate_erp.config import get_settings
    from real_estate_erp.db import authenticate
    token = authenticate(get_settings(), ADMIN_EMAIL, ADMIN_PASSWORD).session_token
    with pytest.raises(psycopg.errors.ReadOnlySqlTransaction):
        with db.acting_transaction(get_settings(), token) as conn:
            conn.execute("UPDATE lands SET street = 'changed'")


# ---- sign-out ------------------------------------------------------------------------------------

def test_logout_requires_the_session_csrf_token(admin):
    response = admin.post("/logout", data={"csrf": "forged"}, follow_redirects=False)
    assert response.status_code == 403
    assert admin.get("/", follow_redirects=False).status_code == 200


def test_logout_revokes_the_session(admin, owner_db):
    csrf = csrf_from(admin.get("/").text)
    response = admin.post("/logout", data={"csrf": csrf}, follow_redirects=False)
    assert response.status_code == 303 and response.headers["location"] == "/login"
    assert admin.get("/", follow_redirects=False).status_code == 303
    revoked = owner_db.execute(
        "SELECT revoked_at IS NOT NULL FROM user_sessions ORDER BY created_at DESC LIMIT 1").fetchone()[0]
    assert revoked


# ---- security headers and data -------------------------------------------------------------------------

def test_security_headers(client):
    headers = client.get("/login").headers
    assert "script-src 'none'" in headers["content-security-policy"]
    assert "frame-ancestors 'none'" in headers["content-security-policy"]
    assert headers["x-frame-options"] == "DENY"
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["cache-control"] == "no-store"


def test_stylesheet_uses_the_emerald_atelier_palette(client):
    css = client.get("/static/css/app.css")
    assert css.status_code == 200
    for colour in ["#183C36", "#C8E0D1", "#F5F2E9", "#D98D75"]:
        assert colour in css.text


def test_only_development_data_no_financial_records(owner_db):
    lands, investors, purchases, entries, movements, sales, _ = counts(owner_db)
    assert (lands, investors, purchases, entries, movements, sales) == (3, 0, 0, 0, 0, 0)
    plans = [r[0] for r in owner_db.execute("SELECT plan_number FROM lands ORDER BY plan_number")]
    assert plans == ["29/ب", "87", "99/أ"]
