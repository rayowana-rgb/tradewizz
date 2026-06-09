"""End-to-end monetization API: subscription gating, radar, portfolio health.

Real JWT auth + injected in-memory subscription/radar/health services and a
fake screen provider, so the gating + permission paths are exercised without a
network or the heavy engine.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.models import Market, ScreenerCategory, ScreenerMatch, ScreenerResult
from app.portfolio_health import router as health_router
from app.portfolio_health.service import PortfolioHealthService
from app.radar import router as radar_router
from app.radar.service import RadarService
from app.subscription import router as sub_router
from app.subscription.service import SubscriptionService
from app.subscription.store import SqliteSubscriptionStore


def _match(symbol, score, change, value, signal="BUY", cats=None):
    return ScreenerMatch(
        symbol=symbol, name=symbol, score=score, signal=signal, price=100.0,
        change_percent=change, categories=cats or [], value_traded=value,
    )


def _us():
    return [
        _match("NVDA", 93, 5.0, 6e9, cats=[ScreenerCategory.bullish]),
        _match("AAPL", 89, 2.0, 4e9),
        _match("MSFT", 86, 1.0, 3e9),
        _match("META", 60, 0.2, 5e8),
    ]


def _idx():
    return [
        _match("BBCA", 90, 3.0, 2e9, cats=[ScreenerCategory.bullish]),
        _match("MPMX", 92, 4.0, 1.5e9,
               cats=[ScreenerCategory.turnaround_multibagger]),
        _match("TPIA", 63, -1.0, 8e8, signal="HOLD"),
    ]


def _provider(market, limit=50, min_score=0.0, min_value_traded=0.0):
    data = {Market.US: _us(), Market.IDX: _idx()}.get(market, [])
    return ScreenerResult(market=market, matches=data[:limit],
                          generated_at="2026-06-09T00:00:00Z")


def _build_client(preview_mode: bool):
    sub = SubscriptionService(
        store=SqliteSubscriptionStore(":memory:"),
        preview_mode=preview_mode,
    )
    sub_router.set_service(sub)
    radar_router.set_service(
        RadarService(_provider, markets=[Market.US, Market.IDX])
    )

    # Simulated positions per user, swappable by the test.
    state = {"positions": []}
    health_router.set_service(
        PortfolioHealthService(
            positions_provider=lambda uid: state["positions"],
            score_provider=lambda s, m: _match("BBCA", 90, 2.0, 3e9),
        )
    )

    c = TestClient(main.app)
    c._state = state  # type: ignore[attr-defined]
    c._sub = sub  # type: ignore[attr-defined]
    return c


@pytest.fixture()
def client():
    """Enforcement-armed client (preview OFF) verifying the dormant paywall."""
    c = _build_client(preview_mode=False)
    yield c
    sub_router.set_service(SubscriptionService())


@pytest.fixture()
def preview_client():
    """Preview-mode client (preview ON): everything open, demand measured."""
    c = _build_client(preview_mode=True)
    yield c
    sub_router.set_service(SubscriptionService())


def _register(c) -> dict:
    email = f"mon_{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/v1/auth/register",
               json={"email": email, "password": "Passw0rd!!"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def _uid(c, headers) -> int:
    return main._get_auth_service().verify_token(
        headers["Authorization"].split(" ", 1)[1]
    )


# --- plans (public) ---------------------------------------------------------
def test_plans_is_public():
    c = TestClient(main.app)
    r = c.get("/v1/subscription/plans")
    assert r.status_code == 200
    tiers = {t["tier"] for t in r.json()["tiers"]}
    assert tiers == {"FREE", "PRO", "ELITE"}


# --- default tier + upgrade -------------------------------------------------
def test_new_user_is_free(client):
    h = _register(client)
    r = client.get("/v1/subscription/me", headers=h)
    assert r.status_code == 200
    assert r.json()["tier"] == "FREE"


def test_upgrade_flow(client):
    h = _register(client)
    r = client.post("/v1/subscription/upgrade", json={"tier": "PRO"}, headers=h)
    assert r.status_code == 200
    assert r.json()["tier"] == "PRO"
    assert client.get("/v1/subscription/me", headers=h).json()["tier"] == "PRO"


# --- radar gating -----------------------------------------------------------
def test_radar_opportunities_locked_for_free(client):
    h = _register(client)
    r = client.get("/v1/radar/opportunities", headers=h)
    assert r.status_code == 402
    assert r.json()["detail"]["required_tier"] == "PRO"


def test_radar_unlocked_for_pro(client):
    h = _register(client)
    client.post("/v1/subscription/upgrade", json={"tier": "PRO"}, headers=h)
    r = client.get("/v1/radar/opportunities", headers=h)
    assert r.status_code == 200
    body = r.json()
    assert "global_top10" in body and "multibagger_candidates" in body


def test_daily_picks_for_pro(client):
    h = _register(client)
    client.post("/v1/subscription/upgrade", json={"tier": "PRO"}, headers=h)
    r = client.get("/v1/radar/daily", headers=h)
    assert r.status_code == 200
    assert r.json()["title"] == "Today's Top Opportunities"


def test_multibagger_requires_elite(client):
    h = _register(client)
    # PRO is not enough for multibagger.
    client.post("/v1/subscription/upgrade", json={"tier": "PRO"}, headers=h)
    assert client.get("/v1/radar/multibagger", headers=h).status_code == 402
    # ELITE unlocks it.
    client.post("/v1/subscription/upgrade", json={"tier": "ELITE"}, headers=h)
    r = client.get("/v1/radar/multibagger", headers=h)
    assert r.status_code == 200
    assert "candidates" in r.json()


# --- portfolio health gating ------------------------------------------------
def test_portfolio_health_requires_elite(client):
    h = _register(client)
    assert client.get("/v1/portfolio/health", headers=h).status_code == 402
    client.post("/v1/subscription/upgrade", json={"tier": "ELITE"}, headers=h)
    r = client.get("/v1/portfolio/health", headers=h)
    assert r.status_code == 200
    assert r.json()["simulated"] is True


def test_radar_requires_auth(client):
    assert client.get("/v1/radar/opportunities").status_code == 401


# --- analyze/screen limit enforcement --------------------------------------
def test_analyze_daily_limit_for_free(client):
    h = _register(client)
    # FREE = 5/day. The 6th analyze must be blocked (402) for an authed user.
    for _ in range(5):
        r = client.get("/v1/analyze/BBCA?market=IDX", headers=h)
        assert r.status_code == 200
    blocked = client.get("/v1/analyze/BBCA?market=IDX", headers=h)
    assert blocked.status_code == 402


def test_analyze_unmetered_when_anonymous(client):
    # No token => unmetered (back-compat). Many calls all succeed.
    for _ in range(8):
        assert client.get("/v1/analyze/BBCA?market=IDX").status_code == 200


def test_screen_limit_capped_for_free(client):
    h = _register(client)
    r = client.get("/v1/screen/IDX?limit=200", headers=h)
    assert r.status_code == 200
    assert r.json()["limit"] <= 20


def test_screen_uncapped_for_pro(client):
    h = _register(client)
    client.post("/v1/subscription/upgrade", json={"tier": "PRO"}, headers=h)
    r = client.get("/v1/screen/IDX?limit=200", headers=h)
    assert r.status_code == 200
    assert r.json()["limit"] == 200


def test_usage_analytics_recorded(client):
    h = _register(client)
    client.post("/v1/subscription/upgrade", json={"tier": "PRO"}, headers=h)
    client.get("/v1/radar/opportunities", headers=h)
    client.get("/v1/analyze/BBCA?market=IDX", headers=h)
    r = client.get("/v1/subscription/usage", headers=h)
    assert r.status_code == 200
    totals = r.json()["totals"]
    assert totals.get("radar_view", 0) >= 1
    assert totals.get("analysis", 0) >= 1


# --- PRO/ELITE Preview pivot: everything open, demand measured --------------
def test_preview_radar_open_for_free(preview_client):
    c = preview_client
    h = _register(c)
    # A FREE user (no upgrade) can open Radar / Daily / Multibagger: no 402.
    assert c.get("/v1/radar/opportunities", headers=h).status_code == 200
    assert c.get("/v1/radar/daily", headers=h).status_code == 200
    assert c.get("/v1/radar/multibagger", headers=h).status_code == 200


def test_preview_portfolio_health_open_for_free(preview_client):
    c = preview_client
    h = _register(c)
    assert c.get("/v1/portfolio/health", headers=h).status_code == 200
    assert c.get("/v1/portfolio/quality", headers=h).status_code == 200


def test_preview_no_analyze_daily_limit(preview_client):
    c = preview_client
    h = _register(c)
    # Old FREE cap was 5/day; in preview, 8 all succeed.
    for _ in range(8):
        assert c.get("/v1/analyze/BBCA?market=IDX", headers=h).status_code == 200


def test_preview_screen_uncapped_for_free(preview_client):
    c = preview_client
    h = _register(c)
    r = c.get("/v1/screen/IDX?limit=200", headers=h)
    assert r.status_code == 200
    assert r.json()["limit"] == 200  # not clamped to 20


def test_preview_entitlements_unlocked(preview_client):
    c = preview_client
    h = _register(c)
    r = c.get("/v1/subscription/entitlements", headers=h)
    assert r.status_code == 200
    body = r.json()
    assert body["preview"] is True
    assert "opportunity_radar" in body["features"]
    assert "portfolio_health" in body["features"]
    assert "opportunity_radar" in body["preview_features"]


def test_preview_plans_flag(preview_client):
    r = preview_client.get("/v1/subscription/plans")
    assert r.status_code == 200
    assert r.json()["preview"] is True


def test_waitlist_join_no_payment(preview_client):
    c = preview_client
    h = _register(c)
    r = c.post("/v1/subscription/waitlist", json={"tier": "PRO"}, headers=h)
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "waitlisted"
    assert body["tier"] == "PRO"
    assert body["preview"] is True
    assert "waiting list" in body["message"].lower()
    # Joining the waitlist does NOT upgrade the tier (no payment taken).
    assert c.get("/v1/subscription/me", headers=h).json()["tier"] == "FREE"


def test_preview_events_recorded_and_demand_breakdown(preview_client):
    c = preview_client
    h = _register(c)
    # Opening preview features records the exact product event names.
    c.get("/v1/radar/opportunities?market=US", headers=h)
    c.get("/v1/radar/daily", headers=h)
    c.get("/v1/radar/multibagger?market=IDX", headers=h)
    c.post(
        "/v1/subscription/event",
        json={"event": "ai_portfolio_manager_opened"},
        headers=h,
    )
    totals = c.get("/v1/subscription/usage", headers=h).json()["totals"]
    assert totals.get("radar_opened", 0) >= 1
    assert totals.get("daily_picks_opened", 0) >= 1
    assert totals.get("multibagger_opened", 0) >= 1
    assert totals.get("ai_portfolio_manager_opened", 0) >= 1
    # Cross-user demand breakdown exposes the per-event meta split.
    demand = c.get(
        "/v1/subscription/demand?metric=radar_opened", headers=h
    ).json()["breakdown"]
    assert any(row["meta"] == "US" for row in demand)
