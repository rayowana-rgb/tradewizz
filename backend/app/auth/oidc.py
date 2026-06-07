"""Server-side verification of Google / Apple identity (ID) tokens.

We verify the JWT signature against the provider's published JWKS and validate
issuer, audience (our client_id), expiry and the provider-specific claims
(Google: email_verified; Apple: subject). Verification is wrapped behind the
``OidcVerifier`` protocol so tests can inject a fake without network access.

No social passwords or long-lived provider tokens are stored: we only read the
verified claims from the short-lived ID token to identify the user.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Protocol

import jwt
from jwt import PyJWKClient

# Provider OIDC discovery constants.
GOOGLE_ISSUERS = {"https://accounts.google.com", "accounts.google.com"}
GOOGLE_JWKS_URI = "https://www.googleapis.com/oauth2/v3/certs"

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URI = "https://appleid.apple.com/auth/keys"


class OidcError(Exception):
    """Raised when an identity token fails verification."""


@dataclass
class VerifiedIdentity:
    """The trusted claims we extract from a verified ID token."""

    provider: str  # "GOOGLE" | "APPLE"
    subject: str  # stable provider user id (the `sub` claim)
    email: Optional[str]
    email_verified: bool


class OidcVerifier(Protocol):
    def verify_google(self, id_token: str, client_id: str) -> VerifiedIdentity:
        ...

    def verify_apple(self, id_token: str, client_id: str) -> VerifiedIdentity:
        ...


def _decode_with_jwks(
    id_token: str,
    *,
    jwks_uri: str,
    issuers: set[str],
    audience: str,
) -> dict:
    """Verify signature + standard claims against a JWKS endpoint."""
    try:
        signing_key = PyJWKClient(jwks_uri).get_signing_key_from_jwt(id_token)
        claims = jwt.decode(
            id_token,
            signing_key.key,
            algorithms=["RS256", "ES256"],
            audience=audience,
            options={"require": ["exp", "iss", "aud", "sub"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise OidcError("Identity token has expired.") from exc
    except jwt.InvalidAudienceError as exc:
        raise OidcError("Identity token audience mismatch.") from exc
    except jwt.PyJWTError as exc:
        raise OidcError(f"Invalid identity token: {exc}") from exc
    except Exception as exc:  # noqa: BLE001 - JWKS fetch / network failures
        raise OidcError(f"Could not verify identity token: {exc}") from exc

    if claims.get("iss") not in issuers:
        raise OidcError("Identity token issuer mismatch.")
    return claims


class JwksOidcVerifier:
    """Default verifier that validates tokens against provider JWKS endpoints."""

    def verify_google(self, id_token: str, client_id: str) -> VerifiedIdentity:
        claims = _decode_with_jwks(
            id_token,
            jwks_uri=GOOGLE_JWKS_URI,
            issuers=GOOGLE_ISSUERS,
            audience=client_id,
        )
        # Google marks verified emails with email_verified (bool or "true").
        ev = claims.get("email_verified", False)
        email_verified = ev is True or str(ev).lower() == "true"
        return VerifiedIdentity(
            provider="GOOGLE",
            subject=str(claims["sub"]),
            email=claims.get("email"),
            email_verified=email_verified,
        )

    def verify_apple(self, id_token: str, client_id: str) -> VerifiedIdentity:
        claims = _decode_with_jwks(
            id_token,
            jwks_uri=APPLE_JWKS_URI,
            issuers={APPLE_ISSUER},
            audience=client_id,
        )
        # Apple may omit email on subsequent logins; subject is the stable id.
        ev = claims.get("email_verified", True)
        email_verified = ev is True or str(ev).lower() == "true"
        return VerifiedIdentity(
            provider="APPLE",
            subject=str(claims["sub"]),
            email=claims.get("email"),
            email_verified=email_verified,
        )
