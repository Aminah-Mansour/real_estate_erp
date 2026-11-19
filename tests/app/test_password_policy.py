"""CAPNOVA password policy (NIST SP 800-63B): 8-128 characters, no composition rules, no expiry,
common/breached and context-specific passwords rejected. Same rules in every environment."""

import pytest

from real_estate_erp import password_policy, security
from real_estate_erp.cli import create_admin
from real_estate_erp.password_policy import MAX_PASSWORD_LENGTH, MIN_PASSWORD_LENGTH, PasswordRejected

from .conftest import ADMIN_EMAIL, ADMIN_PASSWORD, sign_in

EMAIL = "layla.haddad@office.local"


def test_policy_limits():
    assert (MIN_PASSWORD_LENGTH, MAX_PASSWORD_LENGTH) == (8, 128)
    # One policy for the whole application: security.py re-exports the same values.
    assert (security.MIN_PASSWORD_LENGTH, security.MAX_PASSWORD_LENGTH) == (8, 128)


def test_eight_characters_are_enough_and_seven_are_not():
    assert password_policy.problems("Tr7!kq#2", EMAIL) == []
    assert password_policy.problems("Tr7!kq#", EMAIL) == ["use at least 8 characters"]


def test_long_passphrases_up_to_the_maximum_are_accepted():
    phrase = ("violet tangerine harbour lantern " * 4)[:MAX_PASSWORD_LENGTH]
    assert password_policy.problems(phrase, EMAIL) == []
    assert password_policy.problems(phrase + "x", EMAIL) == [f"use at most {MAX_PASSWORD_LENGTH} characters"]


@pytest.mark.parametrize("password", [
    "correct horse battery staple",   # spaces, lowercase only: no composition rules
    "badminton club 9",               # contains "admin" inside an unrelated word
    "نخلة جدة الخضراء",              # Arabic
    "سماء زرقاء",
    "🌴🏠🔑🌙✨🐪🌊⭐",                    # emoji
])
def test_any_characters_and_no_composition_rules(password):
    assert password_policy.problems(password, EMAIL) == []


@pytest.mark.parametrize("password", [
    "password", "Password1", "Password123!", "PASSWORD", "12345678", "123456789", "iloveyou",
    "sunshine", "football", "qwertyuiop", "1q2w3e4r5t", "baseball1", "  password  ",
])
def test_breached_and_common_passwords_are_rejected(password):
    assert any("breached or commonly used" in p for p in password_policy.problems(password, EMAIL))


@pytest.mark.parametrize("password", ["aaaaaaaaaa", "abababab", "abcdefghij", "87654321", "zxcvbnm,./", "!!!!!!!!!", "ضصثقفغعه"])
def test_trivial_patterns_are_rejected(password):
    assert password_policy.problems(password, EMAIL)


@pytest.mark.parametrize("password", [
    "capnova2026", "MyCapnova#1", "CAPNOVA!!", "كابنوفا123", "admin2026!", "Administrator1",
    "realestate1!", "layla.haddad", "Layla.Haddad99", "haddad2026!", "office#2026", EMAIL,
])
def test_service_name_and_own_email_are_rejected(password):
    assert any("service name" in p for p in password_policy.problems(password, EMAIL))


def test_rejection_message_never_contains_the_password():
    with pytest.raises(PasswordRejected) as exc:
        password_policy.check("capnova-secret-77", EMAIL)
    assert "capnova-secret-77" not in str(exc.value)


def test_create_admin_enforces_the_policy_before_touching_the_database():
    # The URL points nowhere: the weak password must be rejected before any connection is attempted.
    for weak in ["short", "password123", "admin@office.local", "capnova2026"]:
        with pytest.raises(PasswordRejected):
            create_admin("postgresql://nobody@127.0.0.1:1/none", "admin@office.local", weak)


def test_passwords_are_hashed_with_argon2id_after_unicode_normalization():
    digest = security.hash_password("Ｓｔｒｏｎｇ ｐａｓｓ ９")         # full-width characters
    assert digest.startswith("$argon2id$")
    assert security.verify_password(digest, "Strong pass 9")          # NFKC: same password
    assert not security.verify_password(digest, "Strong pass 8")
    assert not security.verify_password(digest, "x" * 10_000)          # oversized input is refused cheaply


def test_no_forced_password_change(client, owner_db):
    """An old password keeps working: the policy has no expiry."""
    admin_id = owner_db.execute("SELECT id FROM app_users WHERE email = %s", [ADMIN_EMAIL]).fetchone()[0]
    changed = owner_db.execute("SELECT password_changed_at FROM user_credentials WHERE user_id = %s", [admin_id]).fetchone()[0]
    with owner_db.transaction():
        owner_db.execute("SELECT erp_act_as_internal(%s)", [admin_id])
        owner_db.execute("UPDATE user_credentials SET password_changed_at = now() - interval '5 years' WHERE user_id = %s",
                         [admin_id])
    try:
        response = sign_in(client, ADMIN_EMAIL, ADMIN_PASSWORD)
        assert response.status_code == 303 and response.headers["location"] == "/"
    finally:
        with owner_db.transaction():
            owner_db.execute("SELECT erp_act_as_internal(%s)", [admin_id])
            owner_db.execute("UPDATE user_credentials SET password_changed_at = %s WHERE user_id = %s", [changed, admin_id])
