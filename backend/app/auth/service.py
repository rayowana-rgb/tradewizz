"""Auth service: bcrypt password hashing + JWT access tokens.

Never stores plaintext passwords; never returns the password hash.
"""

from __future__ import annotations

import time
from typing import Optional

import bcrypt
import jwt

from .config import AuthConfig
from .models import AuthResponse, UserProfile
from .store import SqliteUserStore, UserRecord, UserStore


class AuthError(Exception):
    """Auth failure mapped to an HTTP error by the router."""

    def __init__(self, message: str, status_code: int = 400):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode(
        "utf-8"
    )


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return bcrypt.checkpw(
            password.encode("utf-8"), password_hash.encode("utf-8")
        )
    except (ValueError, TypeError):
        return False


class AuthService:
    def __init__(
        self,
        config: Optional[AuthConfig] = None,
        store: Optional[UserStore] = None,
        clock=time.time,
    ):
        self._config = config or AuthConfig.from_env()
        self._store = store or SqliteUserStore(self._config.db_path)
        self._clock = clock

    @property
    def store(self) -> UserStore:
        return self._store

    # -- tokens ----------------------------------------------------------

    def issue_token(self, user_id: int) -> str:
        now = int(self._clock())
        payload = {
            "sub": str(user_id),
            "iat": now,
            "exp": now + self._config.access_token_ttl_seconds,
        }
        return jwt.encode(
            payload, self._config.jwt_secret, algorithm=self._config.jwt_algorithm
        )

    def verify_token(self, token: str) -> int:
        """Return the user id for a valid token, else raise AuthError(401)."""
        try:
            payload = jwt.decode(
                token,
                self._config.jwt_secret,
                algorithms=[self._config.jwt_algorithm],
            )
            return int(payload["sub"])
        except jwt.ExpiredSignatureError as exc:
            raise AuthError("Token expired.", status_code=401) from exc
        except (jwt.InvalidTokenError, KeyError, ValueError) as exc:
            raise AuthError("Invalid token.", status_code=401) from exc

    # -- profile ---------------------------------------------------------

    def _profile(self, rec: UserRecord, connected_brokers: int = 0) -> UserProfile:
        return UserProfile(
            id=rec.id,
            email=rec.email,
            created_at=rec.created_at,
            updated_at=rec.updated_at,
            connected_brokers=connected_brokers,
        )

    # -- public ----------------------------------------------------------

    def register(self, email: str, password: str) -> AuthResponse:
        email = email.strip().lower()
        if self._store.get_by_email(email) is not None:
            raise AuthError("Email already registered.", status_code=409)
        rec = self._store.create(email, hash_password(password))
        return AuthResponse(
            access_token=self.issue_token(rec.id), user=self._profile(rec)
        )

    def login(self, email: str, password: str) -> AuthResponse:
        rec = self._store.get_by_email(email.strip().lower())
        # Same error for unknown email and bad password (no user enumeration).
        if rec is None or not verify_password(password, rec.password_hash):
            raise AuthError("Invalid email or password.", status_code=401)
        return AuthResponse(
            access_token=self.issue_token(rec.id), user=self._profile(rec)
        )

    def me(self, token: str) -> UserProfile:
        user_id = self.verify_token(token)
        rec = self._store.get_by_id(user_id)
        if rec is None:
            raise AuthError("User not found.", status_code=401)
        return self._profile(rec)
