"""Phase 3 (Portfolio intelligence) API + service tests.

Covers, end-to-end with real JWT auth and injected in-memory services:
  * Auto Watchlist AI    (/v1/auto-watchlist/suggestions, /apply, /settings).
  * Portfolio Rebalancing AI (/v1/portfolio/rebalance) ADD/HOLD/REDUCE/EXIT.
  * Global Rotation Engine (/v1/rotation/global) market ranking + recs.
  * Notifications (Phase 3 types) generation.

All rule-based, simulated only, no broker contact.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.cache_layer.cache_manager import CacheManager as _CacheManager
from app.auto_watchlist import router as awl_router
from app.auto_watchlist.service import AutoWatchlistService
from app.auto_watchlist.store import SqliteAutoWatchlistStore
from app.models import Market, ScreenerCategory, ScreenerMatch, ScreenerResult
from app.notifications import router as notif_router
from app.notifications.models import (
    TYPE_AUTO_WATCHLIST_READY,
    TYPE_BEST_MARKET,
    TYPE_REBALANCE_REQUIRED,
    TYPE_ROTATION_CHANGED,
)
from app.notifications.service import NotificationService
from app.notifications.store import SqliteNotificationStore
from app.portfolio_health import router as health_router
from app.portfolio_health.service import PortfolioHealthService
from app.radar import router as radar_router
from app.radar.service import RadarService
from app.rebalance import router as rebal_router
from app.rebalance.service import RebalanceService
from app.rotation import router as rotation_router
from app.rotation.service import GlobalRotationService
from app.subscription import router as sub_router
from app.subscription.service import SubscriptionService
from app.subscription.store import SqliteSubscriptionStore

ALL_MARKETS = list(Market)


# --- fakes ------------------------------------------------------------------
def _match(symbol, score, change, value, signal="BUY", cats=None):
    return ScreenerMatch(
        symbol=symbol, name=symbol, score=score, signal=signal, price=100.0,
        change_percent=change, categories=cats or [], value_traded=value,
    )


def _us():
    # Strong bullish market with many elite + strong names (genuine OVERWEIGHT).
    return [
        _match("NVDA", 96, 6.0, 8e9, cats=[ScreenerCategory.bullish]),
        _match("PLTR", 95, 5.0, 5e9,
               cats=[ScreenerCategory.turnaround_multibagger]),
        _match("MSFT", 94, 4.0, 6e9),
        _match("AVGO", 93, 4.5, 6e9),
        _match("GOOGL", 92, 3.5, 5e9),
        _match("AMZN", 91, 3.0, 5e9),
        _match("AAPL", 90, 2.5, 4e9),
        _match("AMD", 88, 3.0, 3e9),
        _match("TSLA", 87, 2.0, 4e9),
        _match("CRM", 86, 1.8, 2.5e9),
        _match("META", 70, 1.0, 2e9),
        _match("INTC", 55, -1.0, 1e9, signal="HOLD"),
    ]


def _idx():
    return [
        _match("MPMX", 92, 4.0, 2e9,
               cats=[ScreenerCategory.turnaround_multibagger]),
        _match("BBCA", 90, 3.0, 2e9, cats=[ScreenerCategory.bullish]),
        _match("BBRI", 86, 2.0, 1.5e9),
        _match("TPIA", 63, -1.0, 8e8, signal="HOLD"),
    ]


def _bear():
    # A bearish market with NO elite names (mostly declining, low scores).
    return [
        _match("DOWN1", 40, -3.0, 5e8, signal="SELL"),
        _match("DOWN2", 38, -4.0, 4e8, signal="SELL"),
        _match("DOWN3", 35, -2.5, 3e8, signal="HOLD"),
        _match("DOWN4", 30, -5.0, 2e8, signal="SELL"),
    ]


def _provider(market, limit=50, min_score=0.0, min_value_traded=0.0):
    data = {
        Market.US: _us(),
        Market.IDX: _idx(),
        Market.VIETNAM: _bear(),
    }.get(market, [])
    return ScreenerResult(market=market, matches=data[:limit],
                          generated_at="2026-06-09T00:00:00Z")


class _Pos:
    def __init__(self, symbol, market, market_value, unrealized_pnl=0.0):
        self.symbol = symbol
        self.market = market
        self.name = symbol
        self.quantity = 10.0
        self.market_value = market_value
        self.unrealized_pnl = unrealized_pnl


class _Acct:
    def __init__(self, cash, equity):
        self.cash = cash
        self.equity = equity


def _build_client(*, score_map=None):
    """Preview-mode client with Phase-3 services injected (in-memory).

    ``score_map`` overrides per-symbol engine scores for the rebalance rules:
    a dict {symbol: (score, signal, change)}.
    """
    sub = SubscriptionService(
        store=SqliteSubscriptionStore(":memory:"), preview_mode=True
    )
    sub_router.set_service(sub)

    markets = [Market.US, Market.IDX, Market.VIETNAM]
    _cache = _CacheManager()
    radar = RadarService(_provider, markets=markets, cache=_cache)
    radar_router.set_service(radar)

    state = {"positions": [], "account": _Acct(1_000_000.0, 1_000_000.0)}

    score_map = score_map or {}

    def _score(symbol, market):
        if symbol in score_map:
            sc, sig, chg = score_map[symbol]
            return _match(symbol, sc, chg, 3e9, signal=sig)
        return _match(symbol, 90, 2.0, 3e9)

    health = PortfolioHealthService(
        positions_provider=lambda uid: state["positions"],
        score_provider=_score,
    )
    health_router.set_service(health)

    # Auto Watchlist AI.
    awl = AutoWatchlistService(
        radar=radar,
        store=SqliteAutoWatchlistStore(":memory:"),
        positions_provider=lambda uid: state["positions"],
        markets=markets,
    )
    awl_router.set_service(awl)

    # Portfolio Rebalancing AI.
    rebal = RebalanceService(
        health_service=health,
        positions_provider=lambda uid: state["positions"],
        account_provider=lambda uid: state["account"],
        score_provider=_score,
        regime_provider=radar.market_regime,
    )
    rebal_router.set_service(rebal)

    # Global Rotation Engine.
    rotation = GlobalRotationService(
        radar=radar, markets=markets, cache=_cache
    )
    rotation_router.set_service(rotation)

    # Notifications wired with all Phase-3 services.
    notif = NotificationService(
        store=SqliteNotificationStore(":memory:"),
        radar_service=radar,
        health_service=health,
        auto_watchlist_service=awl,
        rebalance_service=rebal,
        rotation_service=rotation,
    )
    notif_router.set_service(notif)

    c = TestClient(main.app)
    c._simstate = state  # type: ignore[attr-defined]
    c._awl = awl  # type: ignore[attr-defined]
    c._rebal = rebal  # type: ignore[attr-defined]
    c._rotation = rotation  # type: ignore[attr-defined]
    c._notif = notif  # type: ignore[attr-defined]
    return c


@pytest.fixture()
def client():
    c = _build_client()
    yield c
    sub_router.set_service(SubscriptionService())


def _register(c) -> dict:
    email = f"p3_{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/v1/auth/register",
               json={"email": email, "password": "Passw0rd!!"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def _uid(c, headers) -> int:
    return main._get_auth_service().verify_token(
        headers["Authorization"].split(" ", 1)[1]
    )


# === Phase A: Auto Watchlist AI ============================================
def test_auto_watchlist_requires_auth():
    c = TestClient(main.app)
    assert c.get("/v1/auto-watchlist/suggestions").status_code == 401


def test_auto_watchlist_suggestions_basic(client):
    h = _register(client)
    r = client.get("/v1/auto-watchlist/suggestions", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["enabled"] is True
    syms = [s["symbol"] for s in body["suggestions"]]
    # Only BUY + score >= 85 names (NVDA/PLTR/MSFT/AAPL/AMD/MPMX/BBCA/BBRI).
    assert "NVDA" in syms and "PLTR" in syms
    # Below-threshold / non-BUY names excluded.
    assert "META" not in syms and "INTC" not in syms and "TPIA" not in syms
    # Bearish VIETNAM market is skipped entirely.
    assert all(s["market"] != "VIETNAM" for s in body["suggestions"])
    # Capped at max_per_day (default 10).
    assert len(body["suggestions"]) <= 10


def test_auto_watchlist_excludes_existing_watchlist(client):
    h = _register(client)
    r = client.get(
        "/v1/auto-watchlist/suggestions",
        params={"existing": ["US:NVDA", "PLTR"]},
        headers=h,
    )
    syms = [s["symbol"] for s in r.json()["suggestions"]]
    assert "NVDA" not in syms  # excluded by MARKET:SYMBOL
    assert "PLTR" not in syms  # excluded by bare symbol


def test_auto_watchlist_excludes_owned_unless_92(client):
    h = _register(client)
    # Own AAPL (score 90 < 92) and AMD (score 88 < 92) -> both excluded.
    client._simstate["positions"] = [
        _Pos("AAPL", Market.US, 100_000.0),
        _Pos("AMD", Market.US, 100_000.0),
        _Pos("NVDA", Market.US, 100_000.0),  # score 96 >= 92 -> kept
    ]
    r = client.get("/v1/auto-watchlist/suggestions", headers=h)
    syms = [s["symbol"] for s in r.json()["suggestions"]]
    assert "AAPL" not in syms
    assert "AMD" not in syms
    assert "NVDA" in syms  # owned but score >= 92


def test_auto_watchlist_apply_adds(client):
    h = _register(client)
    r = client.post(
        "/v1/auto-watchlist/apply",
        json={"items": [{"symbol": "NVDA", "market": "US"}]},
        headers=h,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["count"] == 1
    applied = body["applied"][0]
    assert applied["symbol"] == "NVDA"
    assert applied["source"] == "AUTO_WATCHLIST_AI"
    assert applied["score_at_added"] == 96
    assert applied["market_regime_at_added"] == "BULL"
    assert applied["added_at"]
    # A second apply of the same name is skipped (already applied server-side).
    r2 = client.get("/v1/auto-watchlist/suggestions", headers=h)
    assert "NVDA" not in [s["symbol"] for s in r2.json()["suggestions"]]


def test_auto_watchlist_apply_all(client):
    h = _register(client)
    r = client.post("/v1/auto-watchlist/apply", json={}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["count"] >= 1


def test_auto_watchlist_settings_persist(client):
    h = _register(client)
    # Default settings.
    r = client.get("/v1/auto-watchlist/settings", headers=h)
    assert r.json()["min_score"] == 85.0
    assert r.json()["max_per_day"] == 10
    # Save new settings.
    new = {
        "enabled": True,
        "markets": ["US"],
        "min_score": 90.0,
        "max_per_day": 3,
        "include_multibagger": False,
        "include_daily_picks": True,
    }
    s = client.post("/v1/auto-watchlist/settings", json=new, headers=h)
    assert s.status_code == 200, s.text
    # Re-read => persisted.
    r2 = client.get("/v1/auto-watchlist/settings", headers=h)
    assert r2.json()["min_score"] == 90.0
    assert r2.json()["max_per_day"] == 3
    assert r2.json()["markets"] == ["US"]
    # Suggestions now honor min_score 90 + only US.
    sug = client.get("/v1/auto-watchlist/suggestions", headers=h).json()
    assert all(s["market"] == "US" for s in sug["suggestions"])
    assert all(s["score"] >= 90 for s in sug["suggestions"])
    assert len(sug["suggestions"]) <= 3


def test_auto_watchlist_all_markets_supported(client):
    h = _register(client)
    for m in ALL_MARKETS:
        new = {"enabled": True, "markets": [m.value], "min_score": 85.0,
               "max_per_day": 10, "include_multibagger": True,
               "include_daily_picks": True}
        assert client.post(
            "/v1/auto-watchlist/settings", json=new, headers=h
        ).status_code == 200
        r = client.get("/v1/auto-watchlist/suggestions", headers=h)
        assert r.status_code == 200, (m, r.text)


# === Phase B: Portfolio Rebalancing AI =====================================
def test_rebalance_requires_auth():
    c = TestClient(main.app)
    assert c.get("/v1/portfolio/rebalance").status_code == 401


def test_rebalance_empty_portfolio(client):
    h = _register(client)
    r = client.get("/v1/portfolio/rebalance", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["actions"] == []
    assert body["simulated"] is True
    assert "add a few names" in body["summary"].lower()


def test_rebalance_concentration_causes_reduce():
    # One name at ~80% weight, healthy score -> REDUCE (concentration).
    c = _build_client(score_map={"BIGPOS": (88, "BUY", 2.0),
                                 "SMALL": (80, "BUY", 1.0)})
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("BIGPOS", Market.US, 800_000.0),
        _Pos("SMALL", Market.US, 200_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["BIGPOS"]["action"] == "REDUCE"
    assert by["BIGPOS"]["priority"] == "HIGH"
    assert "concentration" in by["BIGPOS"]["reason"].lower()
    assert body["high_priority_count"] >= 1
    sub_router.set_service(SubscriptionService())


def test_rebalance_weak_score_causes_exit():
    # Very weak score + SELL signal -> EXIT.
    c = _build_client(score_map={"WEAK": (40, "SELL", -3.0),
                                 "OK": (78, "BUY", 1.0)})
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("WEAK", Market.US, 100_000.0),
        _Pos("OK", Market.US, 300_000.0),
        _Pos("OK2", Market.US, 300_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["WEAK"]["action"] == "EXIT"
    assert by["WEAK"]["priority"] == "HIGH"
    sub_router.set_service(SubscriptionService())


def test_rebalance_elite_underweight_causes_add():
    # Elite score (94), high quality, small weight, bullish -> ADD.
    c = _build_client(score_map={"ELITE": (94, "BUY", 5.0),
                                 "F1": (80, "BUY", 1.0),
                                 "F2": (80, "BUY", 1.0),
                                 "F3": (80, "BUY", 1.0),
                                 "F4": (80, "BUY", 1.0)})
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("ELITE", Market.US, 50_000.0),
        _Pos("F1", Market.US, 240_000.0),
        _Pos("F2", Market.US, 240_000.0),
        _Pos("F3", Market.US, 240_000.0),
        _Pos("F4", Market.US, 230_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["ELITE"]["action"] == "ADD"
    assert by["ELITE"]["target_weight"] == 20.0  # elite band
    sub_router.set_service(SubscriptionService())


def test_rebalance_balanced_returns_hold():
    # Mid scores (70-84), balanced weights, no concentration -> HOLD.
    c = _build_client(score_map={"H1": (75, "BUY", 1.0),
                                 "H2": (74, "BUY", 1.0),
                                 "H3": (76, "BUY", 1.0),
                                 "H4": (73, "BUY", 1.0)})
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("H1", Market.US, 250_000.0),
        _Pos("H2", Market.US, 250_000.0),
        _Pos("H3", Market.US, 250_000.0),
        _Pos("H4", Market.US, 250_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    actions = {a["symbol"]: a["action"] for a in body["actions"]}
    assert all(v == "HOLD" for v in actions.values()), actions
    sub_router.set_service(SubscriptionService())


def test_rebalance_profile_changes_cap():
    c = _build_client(score_map={"X": (94, "BUY", 5.0), "Y": (80, "BUY", 1.0)})
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("X", Market.US, 100_000.0),
        _Pos("Y", Market.US, 900_000.0),
    ]
    cons = c.get("/v1/portfolio/rebalance",
                 params={"profile": "Conservative"}, headers=h).json()
    by = {a["symbol"]: a for a in cons["actions"]}
    # Conservative cap is 15% even for an elite name.
    assert by["X"]["target_weight"] == 15.0
    sub_router.set_service(SubscriptionService())


# === Phase C: Global Rotation Engine =======================================
def test_rotation_requires_auth():
    c = TestClient(main.app)
    assert c.get("/v1/rotation/global").status_code == 401


def test_rotation_ranks_markets(client):
    h = _register(client)
    r = client.get("/v1/rotation/global", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    ranks = [m["rank"] for m in body["markets"]]
    assert ranks == sorted(ranks)  # ranks are 1..N in order
    # US (most elites, bullish) should outrank the bearish VIETNAM market.
    by = {m["market"]: m for m in body["markets"]}
    assert by["US"]["rank"] < by["VIETNAM"]["rank"]
    assert body["best_market"] in ("US", "IDX")
    assert body["rotation_summary"]


def test_rotation_bullish_with_elites_is_overweight(client):
    h = _register(client)
    body = client.get("/v1/rotation/global", headers=h).json()
    by = {m["market"]: m for m in body["markets"]}
    assert by["US"]["regime"] == "BULL"
    assert by["US"]["elite_count"] >= 1
    assert by["US"]["recommendation"] == "OVERWEIGHT"


def test_rotation_bearish_no_elites_is_avoid(client):
    h = _register(client)
    body = client.get("/v1/rotation/global", headers=h).json()
    by = {m["market"]: m for m in body["markets"]}
    assert by["VIETNAM"]["regime"] == "BEAR"
    assert by["VIETNAM"]["elite_count"] == 0
    assert by["VIETNAM"]["recommendation"] == "AVOID"


def test_rotation_supports_all_9_markets():
    c = _build_client()
    # Rewire rotation with the full market list so all 9 appear.
    c._rotation = GlobalRotationService(radar=None)  # placeholder
    _cache = _CacheManager()
    radar = RadarService(_provider, markets=ALL_MARKETS, cache=_cache)
    radar_router.set_service(radar)
    rotation_router.set_service(
        GlobalRotationService(radar=radar, markets=ALL_MARKETS, cache=_cache)
    )
    h = _register(c)
    body = c.get("/v1/rotation/global", headers=h).json()
    assert len(body["markets"]) == 9
    assert {m["market"] for m in body["markets"]} == {m.value for m in ALL_MARKETS}
    sub_router.set_service(SubscriptionService())


# === Phase D: Notifications =================================================
def test_notification_auto_watchlist_ready(client):
    h = _register(client)
    r = client.get("/v1/notifications", headers=h)
    assert r.status_code == 200, r.text
    types = [n["notification_type"] for n in r.json()["notifications"]]
    assert TYPE_AUTO_WATCHLIST_READY in types


def test_notification_rebalance_required(client):
    h = _register(client)
    uid = _uid(client, h)
    # A concentrated position -> HIGH-priority rebalance action.
    client._simstate["positions"] = [
        _Pos("BIG", Market.US, 900_000.0),
        _Pos("SMALL", Market.US, 100_000.0),
    ]
    r = client.get("/v1/notifications", headers=h)
    types = [n["notification_type"] for n in r.json()["notifications"]]
    assert TYPE_REBALANCE_REQUIRED in types


def test_notification_best_market_and_rotation_changed(client):
    h = _register(client)
    # Seed a different previous best market so a rotation change is detected.
    client._notif.set_last_best_market("VIETNAM")
    r = client.get("/v1/notifications", headers=h)
    types = [n["notification_type"] for n in r.json()["notifications"]]
    assert TYPE_BEST_MARKET in types
    assert TYPE_ROTATION_CHANGED in types


# === Phase E: Analytics ====================================================
def test_demand_includes_phase3_features(client):
    h = _register(client)
    # Generate some demand.
    client.get("/v1/auto-watchlist/suggestions", headers=h)
    client.post("/v1/auto-watchlist/apply", json={}, headers=h)
    client.get("/v1/portfolio/rebalance", headers=h)
    client.get("/v1/rotation/global", headers=h)
    r = client.get("/v1/analytics/demand", headers=h)
    assert r.status_code == 200, r.text
    labels = {f["feature"] for f in r.json()["most_requested_features"]}
    assert "Auto Watchlist AI" in labels
    assert "Portfolio Rebalancing AI" in labels
    assert "Global Rotation Engine" in labels


def test_rebalance_computes_regime_once_per_market():
    """Regime is a per-MARKET property: many positions in the same market must
    not re-invoke the regime provider per position (perf: avoids redundant
    market scans that pushed large portfolios past the request timeout)."""
    calls = {"n": 0, "markets": []}

    def _counting_regime(market):
        calls["n"] += 1
        calls["markets"].append(market)
        return "bull"

    positions = [
        _Pos("AAA", Market.US, 100_000.0),
        _Pos("BBB", Market.US, 100_000.0),
        _Pos("CCC", Market.US, 100_000.0),
        _Pos("DDD", Market.IDX, 100_000.0),
        _Pos("EEE", Market.IDX, 100_000.0),
    ]

    health = PortfolioHealthService(
        positions_provider=lambda uid: positions,
        score_provider=lambda s, m: _match(s, 80, 1.0, 3e9),
    )
    rebal = RebalanceService(
        health_service=health,
        positions_provider=lambda uid: positions,
        account_provider=lambda uid: _Acct(0.0, 500_000.0),
        score_provider=lambda s, m: _match(s, 80, 1.0, 3e9),
        regime_provider=_counting_regime,
    )

    resp = rebal.rebalance(1)
    assert len(resp.actions) == 5
    # 2 distinct markets (US, IDX) -> regime provider called exactly twice,
    # not once per position (which would be 5).
    assert calls["n"] == 2, calls
    assert set(calls["markets"]) == {Market.US, Market.IDX}
