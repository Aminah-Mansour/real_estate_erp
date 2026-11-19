"""CAPNOVA password policy: one rule set for every environment (development and production alike).

Follows NIST SP 800-63B:

* Length: at least 8 and at most 128 characters (Unicode characters, after NFKC normalization).
  Every character is allowed, including spaces, Arabic letters and emoji.
* No composition rules (no "must contain a digit/symbol") and no periodic password changes.
* Rejected: passwords found in breach corpora or common-password lists, trivial patterns (one repeated
  character, keyboard or alphabet/number runs), and passwords built from the service name or from the
  account's own email address.

The breached/common list is bundled (data/common-passwords.txt.gz, see README) and checked offline, so a
candidate password is never sent to an outside service.

Hashing is Argon2id (see security.py). This module only decides whether a new password is acceptable;
sign-in never re-checks the policy.
"""

import gzip
import unicodedata
from functools import lru_cache
from importlib import resources

MIN_PASSWORD_LENGTH = 8
MAX_PASSWORD_LENGTH = 128

# Names of this service: a password made from them is guessable by anyone who knows where it is used.
SERVICE_WORDS = ("capnova", "كابنوفا", "realestate", "real estate", "realestateerp", "erp", "admin",
                 "administrator", "office", "password", "كلمةالمرور", "كلمة المرور")

_SEQUENCES = (
    "abcdefghijklmnopqrstuvwxyz",
    "0123456789",
    "qwertyuiop", "asdfghjkl", "zxcvbnm",
    "1qaz2wsx3edc4rfv5tgb6yhn7ujm8ik9ol0p",
    "ابتثجحخدذرزسشصضطظعغفقكلمنهوي",
    "ضصثقفغعهخحجد", "شسيبلاتنمكط",
)


class PasswordRejected(ValueError):
    """The new password does not satisfy the policy. str(exc) explains why (no password in the text)."""


def normalize(password: str) -> str:
    """NFKC, so the same characters typed on different keyboards/devices give the same password."""
    return unicodedata.normalize("NFKC", password)


@lru_cache(maxsize=1)
def _blocklist() -> frozenset[str]:
    data = resources.files("real_estate_erp").joinpath("data/common-passwords.txt.gz").read_bytes()
    return frozenset(gzip.decompress(data).decode("utf-8").split("\n")) - {""}


def _strip_affixes(text: str) -> str:
    """'Password123!' -> 'password': drops digits and symbols added before or after a word."""
    start, end = 0, len(text)
    while start < end and not text[start].isalpha():
        start += 1
    while end > start and not text[end - 1].isalpha():
        end -= 1
    return text[start:end]


def _is_trivial(text: str) -> bool:
    compact = text.replace(" ", "")
    if len(set(compact)) <= 2:                                  # aaaaaaaa, abababab, 11112222
        return True
    for seq in _SEQUENCES:                                       # abcdefgh, 87654321, qwertyui
        if compact in seq or compact in seq[::-1]:
            return True
    return False


def _context_words(email: str | None) -> tuple[set[str], set[str]]:
    """(words rejected anywhere in the password, words rejected as the whole password).

    The brand names and the account's own email name are rejected anywhere ("MyCapnova#1"); generic words
    such as "admin" or "office" only when they are the whole password apart from digits and symbols, so
    that unrelated passphrases ("badminton club 9") stay allowed.
    """
    service = {w.replace(" ", "") for w in SERVICE_WORDS}
    anywhere = {"capnova", "كابنوفا"}
    whole = set(service)
    if email:
        email = email.strip().casefold()
        local, _, domain = email.partition("@")
        names = {local} | {p for p in local.replace("-", ".").replace("_", ".").split(".") if p}
        whole |= names | {email, domain.split(".")[0]}
        anywhere |= {email} | {n for n in names if len(n) >= 4 and n not in service}
    return anywhere, {w for w in whole if len(w) >= 3}


def problems(password: str, email: str | None = None) -> list[str]:
    """Every reason the password is rejected (empty list = acceptable). Never includes the password."""
    pw = normalize(password)
    found: list[str] = []
    if len(pw) < MIN_PASSWORD_LENGTH:
        found.append(f"use at least {MIN_PASSWORD_LENGTH} characters")
    if len(pw) > MAX_PASSWORD_LENGTH:
        found.append(f"use at most {MAX_PASSWORD_LENGTH} characters")
    if found:
        return found

    folded = pw.casefold()
    squeezed = folded.replace(" ", "")
    core = _strip_affixes(squeezed)
    blocked = _blocklist()
    if folded in blocked or squeezed in blocked or (len(core) >= MIN_PASSWORD_LENGTH and core in blocked):
        found.append("this password appears in lists of breached or commonly used passwords")
    if _is_trivial(squeezed) or (len(core) >= 4 and _is_trivial(core)):
        found.append("avoid repeated characters and keyboard or alphabet sequences")

    anywhere, whole = _context_words(email)
    if core in whole or squeezed in whole or any(word in squeezed for word in anywhere):
        found.append("do not base the password on the service name or the account's email address")
    return found


def check(password: str, email: str | None = None) -> str:
    """Raises PasswordRejected if the password breaks the policy; returns the normalized password."""
    found = problems(password, email)
    if found:
        raise PasswordRejected("Password rejected: " + "; ".join(found) + ".")
    return normalize(password)
