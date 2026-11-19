"""Password hashing (Argon2id), session tokens and CSRF tokens."""

import hashlib
import hmac
import secrets

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

MIN_PASSWORD_LENGTH = 12

# argon2-cffi's defaults are Argon2id with the RFC 9106 recommended parameters.
_hasher = PasswordHasher()

# Used to spend the same time on unknown accounts as on real ones (no account enumeration by timing).
_DUMMY_HASH = _hasher.hash(secrets.token_urlsafe(24))


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _hasher.verify(password_hash, password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def burn_verification_time(password: str) -> None:
    verify_password(_DUMMY_HASH, password)


def new_session_token() -> str:
    """256 bits of randomness; the database stores only its SHA-256 hash."""
    return secrets.token_urlsafe(32)


def new_csrf_token() -> str:
    return secrets.token_urlsafe(32)


def session_csrf_token(secret_key: str, session_token: str) -> str:
    """CSRF token bound to the session (for forms submitted while signed in)."""
    return hmac.new(secret_key.encode(), b"csrf:" + session_token.encode(), hashlib.sha256).hexdigest()


def tokens_match(expected: str | None, given: str | None) -> bool:
    return bool(expected) and bool(given) and hmac.compare_digest(expected, given)
