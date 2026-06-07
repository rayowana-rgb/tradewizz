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
from .oidc import JwksOidcVerifier, OidcError, OidcVerifier, VerifiedIdentity
from .store import (
    PROVIDER_APPLE,
    PROVIDER_EMAIL,
    PROVIDER_GOOGLE,
    SqliteUserStore,
    UserRecord,
    UserStore,
)


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
        broker_count_provider=None,
        oidc_verifier: Optional[OidcVerifier] = None,
    ):
        self._config = config or AuthConfig.from_env()
        self._store = store or SqliteUserStore(self._config.db_path)
        self._clock = clock
        # Verifies Google/Apple ID tokens. Default validates against the live
        # provider JWKS; tests inject a fake to avoid network access.
        self._oidc = oidc_verifier or JwksOidcVerifier()
        # Optional callable user_id -> int active broker connections. Lets the
        # profile report a real count without a hard dependency on the brokers
        # package (avoids import cycles).
        self._broker_count_provider = broker_count_provider

    def set_broker_count_provider(self, provider) -> None:
        self._broker_count_provider = provider

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

    def _profile(self, rec: UserRecord) -> UserProfile:
        connected = 0
        if self._broker_count_provider is not None:
            try:
                connected = int(self._broker_count_provider(rec.id))
            except Exception:  # noqa: BLE001 - count is best-effort
                connected = 0
        return UserProfile(
            id=rec.id,
            email=rec.email,
            created_at=rec.created_at,
            updated_at=rec.updated_at,
            connected_brokers=connected,
            provider=rec.provider,
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

    # -- social sign-in --------------------------------------------------

    def google_login(self, id_token: str) -> AuthResponse:
        if not self._config.google_enabled:
            raise AuthError(
                "Google Sign-In is not configured.", status_code=503
            )
        try:
            identity = self._oidc.verify_google(
                id_token, self._config.google_client_id
            )
        except OidcError as exc:
            raise AuthError(str(exc), status_code=401) from exc
        return self._social_login(identity)

    def apple_login(self, id_token: str) -> AuthResponse:
        if not self._config.apple_enabled:
            raise AuthError(
                "Apple Sign-In is not configured.", status_code=503
            )
        try:
            identity = self._oidc.verify_apple(
                id_token, self._config.apple_client_id
            )
        except OidcError as exc:
            raise AuthError(str(exc), status_code=401) from exc
        return self._social_login(identity)

    def _social_login(self, identity: VerifiedIdentity) -> AuthResponse:
        """Resolve a verified social identity to a TradeWizz session.

        Returning user (same provider + subject) -> log in.
        New social user -> create an account with an empty password hash
        (we never store the social password or provider tokens).
        Email collides with an EMAIL/other-provider account -> refuse and ask
        the user to log in with that method first (no unsafe auto-linking,
        password_hash is never overwritten).
        """
        provider = identity.provider
        # 1) Returning social user: match by stable provider subject.
        existing = self._store.get_by_provider(provider, identity.subject)
        if existing is not None:
            return AuthResponse(
                access_token=self.issue_token(existing.id),
                user=self._profile(existing),
            )

        # 2) New social user. Require a verified email to create the account.
        email = (identity.email or "").strip().lower()
        if not email:
            raise AuthError(
                "This account did not provide an email address.",
                status_code=400,
            )
        if not identity.email_verified:
            raise AuthError(
                "This account's email is not verified.", status_code=401
            )

        # 3) Email already used by a different account -> do NOT auto-link or
        #    touch the existing password_hash. Ask the user to sign in with the
        #    existing method first (option B).
        clash = self._store.get_by_email(email)
        if clash is not None:
            label = "Google" if provider == PROVIDER_GOOGLE else "Apple"
            raise AuthError(
                "An account with this email already exists. Please login "
                f"with email first to link {label}.",
                status_code=409,
            )

        # 4) Create a fresh social account: empty password hash, no tokens.
        rec = self._store.create(
            email,
            "",  # never store a social password
            provider=provider,
            provider_user_id=identity.subject,
        )
        return AuthResponse(
            access_token=self.issue_token(rec.id), user=self._profile(rec)
        )

    def me(self, token: str) -> UserProfile:
        user_id = self.verify_token(token)
        rec = self._store.get_by_id(user_id)
        if rec is None:
            raise AuthError("User not found.", status_code=401)
        return self._profile(rec)
