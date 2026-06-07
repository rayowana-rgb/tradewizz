"""Tests for Google / Apple social sign-in.

Token verification is faked via an injected OidcVerifier so tests never touch
the network. Covers: not-configured 503, valid token creates user, existing
EMAIL user is not overwritten (option B), and existing email/password login
still works alongside social accounts.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import main
from app.auth.config import AuthConfig
from app.auth.oidc import OidcError, VerifiedIdentity
from app.auth.router import set_service
from app.auth.service import AuthError, AuthService
from app.auth.store import InMemoryUserStore


class FakeVerifier:
    """Maps id_token strings to canned VerifiedIdentity / errors."""

    def __init__(self, table=None):
        self.table = table or {}

    def _resolve(self, id_token, provider, client_id):
        if id_token not in self.table:
            raise OidcError("Invalid identity token.")
        ident = self.table[id_token]
        assert ident.provider == provider
        return ident

    def verify_google(self, id_token, client_id):
        return self._resolve(id_token, "GOOGLE", client_id)

    def verify_apple(self, id_token, client_id):
        return self._resolve(id_token, "APPLE", client_id)


def _google_identity(sub="g-123", email="user@gmail.com", verified=True):
    return VerifiedIdentity(
        provider="GOOGLE", subject=sub, email=email, email_verified=verified
    )


def _apple_identity(sub="a-456", email="user@icloud.com", verified=True):
    return VerifiedIdentity(
        provider="APPLE", subject=sub, email=email, email_verified=verified
    )


def _service(*, google="", apple="", verifier=None, store=None) -> AuthService:
    return AuthService(
        config=AuthConfig(
            jwt_secret="test-secret",
            google_client_id=google,
            apple_client_id=apple,
        ),
        store=store or InMemoryUserStore(),
        oidc_verifier=verifier or FakeVerifier(),
    )


# --------------------------------------------------------------------------- #
# Not configured                                                              #
# --------------------------------------------------------------------------- #
def test_google_not_configured_503():
    svc = _service(google="")  # no client id
    with pytest.raises(AuthError) as ei:
        svc.google_login("anything")
    assert ei.value.status_code == 503
    assert ei.value.message == "Google Sign-In is not configured."


def test_apple_not_configured_503():
    svc = _service(apple="")
    with pytest.raises(AuthError) as ei:
        svc.apple_login("anything")
    assert ei.value.status_code == 503
    assert ei.value.message == "Apple Sign-In is not configured."


# --------------------------------------------------------------------------- #
# Valid token creates a user (no password stored)                             #
# --------------------------------------------------------------------------- #
def test_google_valid_token_creates_user():
    verifier = FakeVerifier({"tok-g": _google_identity()})
    store = InMemoryUserStore()
    svc = _service(google="google-cid", verifier=verifier, store=store)

    res = svc.google_login("tok-g")
    assert res.access_token
    assert res.user.email == "user@gmail.com"
    assert res.user.provider == "GOOGLE"

    rec = store.get_by_email("user@gmail.com")
    assert rec is not None
    assert rec.provider == "GOOGLE"
    assert rec.provider_user_id == "g-123"
    # No social password is ever stored.
    assert rec.password_hash == ""


def test_apple_valid_token_creates_user():
    verifier = FakeVerifier({"tok-a": _apple_identity()})
    store = InMemoryUserStore()
    svc = _service(apple="apple-cid", verifier=verifier, store=store)

    res = svc.apple_login("tok-a")
    assert res.user.email == "user@icloud.com"
    assert res.user.provider == "APPLE"

    rec = store.get_by_provider("APPLE", "a-456")
    assert rec is not None
    assert rec.password_hash == ""


def test_returning_social_user_logs_in_no_duplicate():
    verifier = FakeVerifier({"tok-g": _google_identity()})
    store = InMemoryUserStore()
    svc = _service(google="cid", verifier=verifier, store=store)

    first = svc.google_login("tok-g")
    second = svc.google_login("tok-g")
    assert first.user.id == second.user.id  # same account, not a duplicate


def test_unverified_email_rejected():
    verifier = FakeVerifier({"tok-g": _google_identity(verified=False)})
    svc = _service(google="cid", verifier=verifier)
    with pytest.raises(AuthError) as ei:
        svc.google_login("tok-g")
    assert ei.value.status_code == 401


# --------------------------------------------------------------------------- #
# Existing EMAIL user is NOT overwritten (option B)                           #
# --------------------------------------------------------------------------- #
def test_social_does_not_overwrite_existing_email_user():
    store = InMemoryUserStore()
    verifier = FakeVerifier(
        {"tok-g": _google_identity(email="taken@x.com")}
    )
    svc = _service(google="cid", verifier=verifier, store=store)

    # Pre-existing EMAIL account with a real password hash.
    email_user = svc.register("taken@x.com", "password123")
    original_hash = store.get_by_email("taken@x.com").password_hash
    assert original_hash and original_hash != ""

    with pytest.raises(AuthError) as ei:
        svc.google_login("tok-g")
    assert ei.value.status_code == 409
    assert "already exists" in ei.value.message
    assert "login with email first to link Google" in ei.value.message

    # The password hash and account are untouched.
    rec = store.get_by_email("taken@x.com")
    assert rec.password_hash == original_hash
    assert rec.provider == "EMAIL"
    assert rec.id == email_user.user.id


# --------------------------------------------------------------------------- #
# Existing email/password login still works alongside social                  #
# --------------------------------------------------------------------------- #
def test_email_login_still_works():
    svc = _service(google="cid", apple="cid")
    svc.register("classic@x.com", "password123")
    res = svc.login("classic@x.com", "password123")
    assert res.access_token
    assert res.user.provider == "EMAIL"


# --------------------------------------------------------------------------- #
# API-level: endpoints behave end-to-end                                      #
# --------------------------------------------------------------------------- #
@pytest.fixture()
def client_factory():
    created = []

    def make(**kw):
        svc = _service(**kw)
        set_service(svc)
        created.append(svc)
        return TestClient(main.app), svc

    yield make
    set_service(_service())  # reset to a clean disabled service


def test_api_google_not_configured_503(client_factory):
    client, _ = client_factory(google="")
    r = client.post("/v1/auth/google", json={"id_token": "x"})
    assert r.status_code == 503
    assert r.json()["detail"] == "Google Sign-In is not configured."


def test_api_apple_not_configured_503(client_factory):
    client, _ = client_factory(apple="")
    r = client.post("/v1/auth/apple", json={"id_token": "x"})
    assert r.status_code == 503
    assert r.json()["detail"] == "Apple Sign-In is not configured."


def test_api_google_valid_creates_and_returns_jwt(client_factory):
    verifier = FakeVerifier({"tok-g": _google_identity()})
    client, svc = client_factory(google="cid", verifier=verifier)
    r = client.post("/v1/auth/google", json={"id_token": "tok-g"})
    assert r.status_code == 200
    body = r.json()
    assert body["token_type"] == "bearer"
    assert body["access_token"]
    assert body["user"]["provider"] == "GOOGLE"
    # No secrets leaked.
    assert "password" not in r.text.lower()
    # The returned JWT validates back to the created user.
    assert svc.verify_token(body["access_token"]) == body["user"]["id"]


def test_api_apple_valid_creates_and_returns_jwt(client_factory):
    verifier = FakeVerifier({"tok-a": _apple_identity()})
    client, _ = client_factory(apple="cid", verifier=verifier)
    r = client.post("/v1/auth/apple", json={"id_token": "tok-a"})
    assert r.status_code == 200
    assert r.json()["user"]["provider"] == "APPLE"


def test_api_google_invalid_token_401(client_factory):
    client, _ = client_factory(google="cid", verifier=FakeVerifier({}))
    r = client.post("/v1/auth/google", json={"id_token": "bogus"})
    assert r.status_code == 401
