"""Settings, read from environment variables (or a local .env file) with the ERP_ prefix."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="ERP_", env_file=".env", extra="ignore")

    # This MVP only runs against development data.
    env: str = "development"

    # Database logins: the application (erp_app), the login service (erp_auth) and, for setup and
    # migrations only, the schema owner.
    app_database_url: str
    auth_database_url: str
    owner_database_url: str | None = None

    # Signs per-session CSRF tokens. Long random value, never committed.
    secret_key: str

    session_hours: int = 8


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    if settings.env != "development":
        raise RuntimeError("This MVP runs with development data only: set ERP_ENV=development.")
    if len(settings.secret_key) < 32:
        raise RuntimeError("ERP_SECRET_KEY must be at least 32 characters of random data.")
    return settings
