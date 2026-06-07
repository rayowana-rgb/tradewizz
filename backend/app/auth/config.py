"""Auth configuration from environment (no secrets in source)."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _i(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class AuthConfig:
    # JWT signing. Override TRADEWIZZ_JWT_SECRET in production.
    jwt_secret: str = "tradewizz-dev-jwt-secret"
    jwt_algorithm: str = "HS256"
    access_token_ttl_seconds: int = 7 * 24 * 60 * 60  # 7 days
    # SQLite database file for users.
    db_path: str = ""

    @classmethod
    def from_env(cls) -> "AuthConfig":
        default_db = str(
            Path(__file__).resolve().parent.parent.parent / "data" / "tradewizz.db"
        )
        return cls(
            jwt_secret=os.environ.get(
                "TRADEWIZZ_JWT_SECRET", "tradewizz-dev-jwt-secret"
            ),
            jwt_algorithm=os.environ.get("TRADEWIZZ_JWT_ALG", "HS256"),
            access_token_ttl_seconds=_i(
                "TRADEWIZZ_JWT_TTL_SECONDS", 7 * 24 * 60 * 60
            ),
            db_path=os.environ.get("TRADEWIZZ_DB_PATH", default_db),
        )
