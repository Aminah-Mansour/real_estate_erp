"""Password hashing (Argon2id), session tokens and CSRF tokens."""

import hashlib
import hmac
import secrets

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

from .password_policy import MAX_PASSWORD_LENGTH, MIN_PASSWORD_LENGTH, normalize  # noqa: F401 (re-exported)

# argon2-cffi's defaults are Argon2id with the RFC 9106 recommended parameters.
_hasher = PasswordHasher()

# Used to spend the same time on unknown accounts as on real ones (no account enumeration by timing).
_DUMMY_HASH = _hasher.hash(secrets.token_urlsafe(24))


def hash_password(password: str) -> str:
    """Argon2id hash of the NFKC-normalized password (the policy is checked by password_policy.check)."""
    return _hasher.hash(normalize(password))


def verify_password(password_hash: str, password: str) -> bool:
    # Inputs far beyond the policy maximum are refused without hashing (cheap protection against huge posts).
    if len(password) > 4 * MAX_PASSWORD_LENGTH:
        return False
    try:
        return _hasher.verify(password_hash, normalize(password))
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
