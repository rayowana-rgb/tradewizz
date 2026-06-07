"""Auth tests: register, login, invalid password, JWT validation.

Uses an in-memory user store (no disk, no network).
"""

import time

import pytest
from fastapi.testclient import TestClient

from app import main
from app.auth.config import AuthConfig
from app.auth.router import set_service
from app.auth.service import (
    AuthError,
    AuthService,
    hash_password,
    verify_password,
)
from app.auth.store import InMemoryUserStore


def _service(**cfg) -> AuthService:
    return AuthService(
        config=AuthConfig(jwt_secret="test-secret", **cfg),
        store=InMemoryUserStore(),
    )


# --- password hashing -------------------------------------------------------

def test_password_hash_is_not_plaintext_and_verifies():
    h = hash_password("password123")
    assert h != "password123"
    assert "password123" not in h
    assert verify_password("password123", h) is True
    assert verify_password("wrong", h) is False


# --- register ---------------------------------------------------------------

def test_register_returns_token_and_profile():
    svc = _service()
    res = svc.register("a@b.com", "password123")
    assert res.access_token
    assert res.user.email == "a@b.com"
    assert res.user.id == 1
    assert res.user.connected_brokers == 0


def test_register_stores_hash_not_plaintext():
    store = InMemoryUserStore()
    svc = AuthService(config=AuthConfig(jwt_secret="x"), store=store)
    svc.register("a@b.com", "password123")
    rec = store.get_by_email("a@b.com")
    assert rec.password_hash != "password123"
    assert verify_password("password123", rec.password_hash)


def test_duplicate_email_rejected():
    svc = _service()
    svc.register("a@b.com", "password123")
    with pytest.raises(AuthError) as ei:
        svc.register("A@B.COM", "password123")  # case-insensitive
    assert ei.value.status_code == 409


# --- login ------------------------------------------------------------------

def test_login_succeeds_with_correct_password():
    svc = _service()
    svc.register("a@b.com", "password123")
    res = svc.login("a@b.com", "password123")
    assert res.access_token
    assert res.user.email == "a@b.com"


def test_login_fails_with_invalid_password():
    svc = _service()
    svc.register("a@b.com", "password123")
    with pytest.raises(AuthError) as ei:
        svc.login("a@b.com", "wrong-password")
    assert ei.value.status_code == 401


def test_login_unknown_email_same_error_as_bad_password():
    svc = _service()
    with pytest.raises(AuthError) as ei:
        svc.login("nobody@b.com", "whatever1")
    assert ei.value.status_code == 401


# --- JWT validation ---------------------------------------------------------

def test_token_round_trips_to_user_id():
    svc = _service()
    res = svc.register("a@b.com", "password123")
    user_id = svc.verify_token(res.access_token)
    assert user_id == res.user.id


def test_me_returns_profile_for_valid_token():
    svc = _service()
    res = svc.register("a@b.com", "password123")
    profile = svc.me(res.access_token)
    assert profile.email == "a@b.com"


def test_invalid_token_rejected():
    svc = _service()
    with pytest.raises(AuthError) as ei:
        svc.verify_token("not-a-jwt")
    assert ei.value.status_code == 401


def test_expired_token_rejected():
    clock = {"t": 1000.0}
    svc = AuthService(
        config=AuthConfig(jwt_secret="x", access_token_ttl_seconds=60),
        store=InMemoryUserStore(),
        clock=lambda: clock["t"],
    )
    res = svc.register("a@b.com", "password123")
    clock["t"] += 61
    with pytest.raises(AuthError) as ei:
        svc.verify_token(res.access_token)
    assert ei.value.status_code == 401


def test_token_signed_with_different_secret_rejected():
    svc_a = _service()
    res = svc_a.register("a@b.com", "password123")
    # A service with a different secret must reject the token.
    svc_b = AuthService(config=AuthConfig(jwt_secret="other"),
                        store=InMemoryUserStore())
    with pytest.raises(AuthError):
        svc_b.verify_token(res.access_token)


# --- API endpoints (TestClient + in-memory service) -------------------------

@pytest.fixture()
def client():
    set_service(_service())
    yield TestClient(main.app)
    set_service(_service())  # reset


def test_api_register_login_me_logout(client):
    r = client.post("/v1/auth/register",
                    json={"email": "u@x.com", "password": "password123"})
    assert r.status_code == 200
    token = r.json()["access_token"]
    # No secrets leaked.
    assert "password" not in r.text.lower()
    assert "hash" not in r.text.lower()

    assert client.post("/v1/auth/login",
                       json={"email": "u@x.com",
                             "password": "password123"}).status_code == 200

    me = client.get("/v1/auth/me",
                    headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200
    assert me.json()["email"] == "u@x.com"

    assert client.post(
        "/v1/auth/logout",
        headers={"Authorization": f"Bearer {token}"},
    ).status_code == 200


def test_api_login_invalid_password_401(client):
    client.post("/v1/auth/register",
                json={"email": "u@x.com", "password": "password123"})
    r = client.post("/v1/auth/login",
                    json={"email": "u@x.com", "password": "nope-nope"})
    assert r.status_code == 401


def test_api_me_without_token_401(client):
    assert client.get("/v1/auth/me").status_code == 401


def test_api_register_short_password_422(client):
    r = client.post("/v1/auth/register",
                    json={"email": "u@x.com", "password": "short"})
    assert r.status_code == 422  # min_length=8


def test_api_register_invalid_email_422(client):
    r = client.post("/v1/auth/register",
                    json={"email": "not-an-email", "password": "password123"})
    assert r.status_code == 422
