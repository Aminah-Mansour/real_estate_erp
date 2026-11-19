"""Real Estate ERP MVP: server-rendered pages (FastAPI + Jinja2).

* Administrator sign-in only; sessions are verified by the database on every request.
* Every page is read-only (the database transaction is switched to READ ONLY after naming the employee).
* Arabic (default, right-to-left) and English.
"""

from pathlib import Path
from urllib.parse import urlparse
from uuid import UUID

from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import db, i18n, queries
from .config import get_settings
from .security import new_csrf_token, session_csrf_token, tokens_match

BASE_DIR = Path(__file__).resolve().parent
SESSION_COOKIE = "erp_session"
LOGIN_CSRF_COOKIE = "erp_login_csrf"
LANG_COOKIE = "erp_lang"

CONTENT_SECURITY_POLICY = (
    "default-src 'self'; "
    "style-src 'self' https://fonts.googleapis.com; "
    "font-src https://fonts.gstatic.com; "
    "img-src 'self' data:; "
    "script-src 'none'; "
    "form-action 'self'; "
    "frame-ancestors 'none'; "
    "base-uri 'none'; "
    "object-src 'none'"
)

settings = get_settings()
app = FastAPI(title="Real Estate ERP", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["Content-Security-Policy"] = CONTENT_SECURITY_POLICY
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "same-origin"
    response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    response.headers["Strict-Transport-Security"] = "max-age=31536000"
    if not request.url.path.startswith("/static/"):
        response.headers["Cache-Control"] = "no-store"
    return response


# ---- helpers -------------------------------------------------------------------------------------

def _lang(request: Request) -> str:
    return i18n.language(request.cookies.get(LANG_COOKIE))


def _context(request: Request, **extra) -> dict:
    lang = _lang(request)
    return {
        "lang": lang,
        "dir": i18n.DIRECTION[lang],
        "t": i18n.translator(lang),
        "money": lambda v: i18n.money(v, lang),
        "qty": lambda v, unit: i18n.quantity(v, unit, lang),
        "count": i18n.count,
        "ts": lambda v: i18n.timestamp(v, lang),
        "action_label": lambda a: i18n.action_label(a, lang),
        "entity_label": lambda e: i18n.entity_label(e, lang),
        "current_path": request.url.path,
        **extra,
    }


def _set_cookie(response: Response, name: str, value: str, max_age: int | None) -> None:
    response.set_cookie(name, value, max_age=max_age, httponly=True, secure=True, samesite="strict", path="/")


def _to_login(request: Request, message: str | None = None) -> RedirectResponse:
    response = RedirectResponse("/login" + (f"?m={message}" if message else ""), status_code=303)
    response.delete_cookie(SESSION_COOKIE, path="/", secure=True, httponly=True, samesite="strict")
    return response


def _safe_next(value: str | None) -> str:
    """Only same-site relative paths (no open redirects)."""
    if not value or not value.startswith("/") or value.startswith("//") or "\\" in value:
        return "/"
    parsed = urlparse(value)
    return "/" if parsed.scheme or parsed.netloc else value


def _page(request: Request, template: str, active: str, load) -> Response:
    """Renders a signed-in page. load(conn) returns the page's data, read inside a read-only transaction."""
    token = request.cookies.get(SESSION_COOKIE)
    try:
        with db.acting_transaction(settings, token) as conn:
            employee = queries.current_employee(conn)
            data = load(conn)
    except db.SessionInvalid:
        return _to_login(request, "expired" if token else None)
    if data is None:
        return _not_found(request, employee, token)
    return templates.TemplateResponse(
        request, template,
        _context(request, employee=employee, active=active, csrf=session_csrf_token(settings.secret_key, token), **data),
    )


def _not_found(request: Request, employee=None, token=None) -> Response:
    ctx = _context(request, employee=employee, active="",
                   csrf=session_csrf_token(settings.secret_key, token) if token else "")
    return templates.TemplateResponse(request, "not_found.html", ctx, status_code=404)


# ---- sign in / sign out ------------------------------------------------------------------------------

@app.get("/login", response_class=HTMLResponse)
def login_form(request: Request, m: str | None = None):
    token = request.cookies.get(SESSION_COOKIE)
    if token:
        try:
            with db.acting_transaction(settings, token):
                pass
            return RedirectResponse("/", status_code=303)
        except db.SessionInvalid:
            pass
    csrf = new_csrf_token()
    messages = {"expired": "login_expired", "form": "login_form_expired"}
    response = templates.TemplateResponse(
        request, "login.html", _context(request, csrf=csrf, error=None, notice=messages.get(m or ""), email=""))
    _set_cookie(response, LOGIN_CSRF_COOKIE, csrf, max_age=1800)
    return response


@app.post("/login")
def login(request: Request, email: str = Form(""), password: str = Form(""), csrf: str = Form("")):
    if not tokens_match(request.cookies.get(LOGIN_CSRF_COOKIE), csrf):
        return RedirectResponse("/login?m=form", status_code=303)
    result = db.authenticate(settings, email, password)
    if not result.ok:
        new_csrf = new_csrf_token()
        error = "login_not_admin" if result.reason == "not_admin" else "login_invalid"
        response = templates.TemplateResponse(
            request, "login.html", _context(request, csrf=new_csrf, error=error, notice=None, email=email),
            status_code=401)
        _set_cookie(response, LOGIN_CSRF_COOKIE, new_csrf, max_age=1800)
        return response
    response = RedirectResponse("/", status_code=303)
    _set_cookie(response, SESSION_COOKIE, result.session_token, max_age=settings.session_hours * 3600)
    response.delete_cookie(LOGIN_CSRF_COOKIE, path="/", secure=True, httponly=True, samesite="strict")
    return response


@app.post("/logout")
def logout(request: Request, csrf: str = Form("")):
    token = request.cookies.get(SESSION_COOKIE)
    if not token or not tokens_match(session_csrf_token(settings.secret_key, token), csrf):
        return Response("Invalid or missing CSRF token", status_code=403)
    db.end_session(settings, token)
    return _to_login(request)


@app.get("/lang/{code}")
def switch_language(code: str, next: str | None = None):
    response = RedirectResponse(_safe_next(next), status_code=303)
    _set_cookie(response, LANG_COOKIE, i18n.language(code), max_age=365 * 24 * 3600)
    return response


# ---- pages (all read-only) ------------------------------------------------------------------------------

@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request):
    def load(conn):
        return {
            "totals": queries.land_totals(conn),
            "lands": queries.lands(conn),
            "statuses": queries.land_status_counts(conn),
            "activity": queries.recent_activity(conn),
        }
    return _page(request, "dashboard.html", "dashboard", load)


@app.get("/lands", response_class=HTMLResponse)
def lands(request: Request):
    return _page(request, "lands.html", "lands",
                 lambda conn: {"lands": queries.lands(conn), "totals": queries.land_totals(conn)})


@app.get("/lands/{land_id}", response_class=HTMLResponse)
def land_detail(request: Request, land_id: UUID):
    def load(conn):
        row = queries.land(conn, land_id)
        return None if row is None else {"land": row}
    return _page(request, "land_detail.html", "lands", load)


@app.get("/investors", response_class=HTMLResponse)
def investors(request: Request):
    return _page(request, "module.html", "investors",
                 lambda conn: {"module": "investors", "counts": queries.module_counts(conn)})


@app.get("/portfolios", response_class=HTMLResponse)
def portfolios(request: Request):
    return _page(request, "module.html", "portfolios",
                 lambda conn: {"module": "portfolios", "counts": queries.module_counts(conn)})


@app.get("/accounting", response_class=HTMLResponse)
def accounting(request: Request):
    return _page(request, "module.html", "accounting",
                 lambda conn: {"module": "accounting", "counts": queries.module_counts(conn)})


@app.exception_handler(StarletteHTTPException)
async def http_error(request: Request, exc: StarletteHTTPException):
    if exc.status_code == 404:
        return templates.TemplateResponse(request, "not_found.html",
                                          _context(request, employee=None, active="", csrf=""), status_code=404)
    return Response(str(exc.detail), status_code=exc.status_code)
