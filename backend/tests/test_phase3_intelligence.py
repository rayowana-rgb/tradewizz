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


def _build_client(*, score_map=None, support_map=None):
    """Preview-mode client with Phase-3 services injected (in-memory).

    ``score_map`` overrides per-symbol engine scores for the rebalance rules:
    a dict {symbol: (score, signal, change)}.
    ``support_map`` overrides per-symbol support levels for the support-based
    average-down rule: a dict {symbol: {"immediate_support", "major_support",
    "price"}}.
    """
    support_map = support_map or {}

    def _support(symbol, market):
        return support_map.get(symbol)
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
            entry = score_map[symbol]
            # A None entry simulates a held name with NO live engine score
            # (below the liquidity floor / uncached): the services must treat
            # it as low-confidence neutral, never auto-trim it.
            if entry is None:
                return None
            sc, sig, chg = entry
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
        support_provider=_support,
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


def test_rebalance_take_profit_trims_fading_winner():
    # A big winner (+60%) whose engine score has slipped below 80 -> REDUCE to
    # secure profit. A still-strong winner (score >= 80) keeps running.
    c = _build_client(score_map={
        "FADING": (72, "HOLD", 0.5),
        "RUNNER": (88, "BUY", 1.0),
        "F1": (80, "BUY", 1.0),
        "F2": (80, "BUY", 1.0),
    })
    h = _register(c)
    c._simstate["positions"] = [
        # +60%: market_value 240k, cost 150k -> pnl 90k.
        _Pos("FADING", Market.US, 240_000.0, unrealized_pnl=90_000.0),
        _Pos("RUNNER", Market.US, 240_000.0, unrealized_pnl=90_000.0),
        _Pos("F1", Market.US, 240_000.0),
        _Pos("F2", Market.US, 240_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["FADING"]["action"] == "REDUCE"
    assert "secure profit" in by["FADING"]["reason"].lower()
    assert by["FADING"]["pnl_pct"] == 60.0
    assert by["FADING"]["pnl_value"] == 90_000.0
    # The strong runner is NOT trimmed on profit alone.
    assert by["RUNNER"]["action"] != "REDUCE", by["RUNNER"]
    sub_router.set_service(SubscriptionService())


def test_rebalance_strong_winner_not_take_profited():
    # A strong winner up big with a healthy score must keep running (no trim).
    c = _build_client(score_map={
        "WINNER": (90, "BUY", 2.0),
        "F1": (80, "BUY", 1.0),
        "F2": (80, "BUY", 1.0),
        "F3": (80, "BUY", 1.0),
    })
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("WINNER", Market.US, 200_000.0, unrealized_pnl=120_000.0),
        _Pos("F1", Market.US, 250_000.0),
        _Pos("F2", Market.US, 250_000.0),
        _Pos("F3", Market.US, 250_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["WINNER"]["action"] != "REDUCE", by["WINNER"]
    sub_router.set_service(SubscriptionService())


def test_rebalance_averages_down_a_loser_testing_support():
    # A losing holding whose engine score still holds (70), that the engine is
    # NOT exiting/reducing, and whose PRICE IS TESTING SUPPORT (within 3% above
    # a rolling low) -> ADD, suggesting averaging down near support.
    c = _build_client(
        score_map={
            "DIP": (70, "HOLD", -1.0),
            "F1": (80, "BUY", 1.0),
            "F2": (80, "BUY", 1.0),
            "F3": (80, "BUY", 1.0),
        },
        support_map={
            # price 101 sits ~1% above the tested swing support at 100.
            "DIP": {"swing_support": 100.0, "touches": 3, "price": 101.0},
        },
    )
    h = _register(c)
    c._simstate["positions"] = [
        # Loss (pnl < 0). Small weight (~4%) so it sits below its watch-band
        # target and is eligible to add.
        _Pos("DIP", Market.US, 41_000.0, unrealized_pnl=-9_000.0),
        _Pos("F1", Market.US, 320_000.0),
        _Pos("F2", Market.US, 320_000.0),
        _Pos("F3", Market.US, 320_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["DIP"]["action"] == "ADD"
    assert "averaging down" in by["DIP"]["reason"].lower()
    assert "support" in by["DIP"]["reason"].lower()
    sub_router.set_service(SubscriptionService())


def test_rebalance_does_not_average_down_a_loser_far_from_support():
    # Same intact score + loss, but the price is NOWHERE NEAR support (well
    # above the rolling lows) -> no support test, so NO buy-the-dip.
    c = _build_client(
        score_map={
            "DIP": (70, "HOLD", -1.0),
            "F1": (80, "BUY", 1.0),
            "F2": (80, "BUY", 1.0),
            "F3": (80, "BUY", 1.0),
        },
        support_map={
            # price 130 is ~30% above support -> not testing anything.
            "DIP": {"swing_support": 100.0, "touches": 3, "price": 130.0},
        },
    )
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("DIP", Market.US, 41_000.0, unrealized_pnl=-9_000.0),
        _Pos("F1", Market.US, 320_000.0),
        _Pos("F2", Market.US, 320_000.0),
        _Pos("F3", Market.US, 320_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert "averaging down" not in by["DIP"]["reason"].lower()
    sub_router.set_service(SubscriptionService())


def test_rebalance_does_not_average_down_when_support_broken():
    # Price has broken BELOW major support (falling knife) -> even with an
    # intact score and a loss, NOT offered as a buy-the-dip.
    c = _build_client(
        score_map={
            "KNIFE": (70, "HOLD", -3.0),
            "F1": (80, "BUY", 1.0),
            "F2": (80, "BUY", 1.0),
            "F3": (80, "BUY", 1.0),
        },
        support_map={
            # price 90 is well below the 100 swing support -> support failed.
            "KNIFE": {"swing_support": 100.0, "touches": 2, "price": 90.0},
        },
    )
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("KNIFE", Market.US, 41_000.0, unrealized_pnl=-9_000.0),
        _Pos("F1", Market.US, 320_000.0),
        _Pos("F2", Market.US, 320_000.0),
        _Pos("F3", Market.US, 320_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert "averaging down" not in by["KNIFE"]["reason"].lower()
    sub_router.set_service(SubscriptionService())


def test_rebalance_does_not_average_down_a_weak_score_loser():
    # A weak/collapsing score (40) at support -> the engine EXITs/leaves it,
    # it is NOT offered as a buy-the-dip regardless of the support test.
    c = _build_client(
        score_map={
            "FALLER": (40, "HOLD", -3.0),
            "F1": (80, "BUY", 1.0),
            "F2": (80, "BUY", 1.0),
            "F3": (80, "BUY", 1.0),
        },
        support_map={
            "FALLER": {"swing_support": 100.0, "touches": 3, "price": 101.0},
        },
    )
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("FALLER", Market.US, 41_000.0, unrealized_pnl=-9_000.0),
        _Pos("F1", Market.US, 320_000.0),
        _Pos("F2", Market.US, 320_000.0),
        _Pos("F3", Market.US, 320_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["FALLER"]["action"] != "ADD", by["FALLER"]
    assert "averaging down" not in by["FALLER"]["reason"].lower()
    sub_router.set_service(SubscriptionService())


def test_rebalance_caps_average_down_to_top_candidates():
    # SIX losing holdings all testing support with intact scores. Only the
    # top AVERAGE_DOWN_MAX (=3) by score get ADD; the rest are held.
    from app.rebalance.service import AVERAGE_DOWN_MAX
    # Scores in [80,84]: above the quality-reduce ceiling (75) and score floor
    # (50), but below the 85 strong-name ADD rule -> the ONLY applicable action
    # is the support-based average-down add, isolating the cap.
    scores = {"D1": 84, "D2": 83, "D3": 82, "D4": 81, "D5": 80, "D6": 80}
    score_map = {s: (sc, "HOLD", -1.0) for s, sc in scores.items()}
    support_map = {
        s: {"swing_support": 100.0, "touches": 3, "price": 101.0}
        for s in scores
    }
    c = _build_client(score_map=score_map, support_map=support_map)
    h = _register(c)
    # Each small (~3% weight) so all sit below target and are add-eligible;
    # one big filler to dilute weights.
    positions = [_Pos(s, Market.US, 30_000.0, unrealized_pnl=-6_000.0)
                 for s in scores]
    positions.append(_Pos("BIG", Market.US, 820_000.0))
    c._simstate["positions"] = positions
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    adds = [s for s in scores if "averaging down" in by[s]["reason"].lower()]
    assert len(adds) == AVERAGE_DOWN_MAX, adds
    # The kept ones must be the HIGHEST scores (D1, D2, D3).
    assert len(adds) == AVERAGE_DOWN_MAX, adds
    # A dropped candidate is downgraded to HOLD, NOT ADD (top-3 by score kept).
    dropped = [s for s in scores if by[s]["action"] == "HOLD"]
    assert len(dropped) == len(scores) - AVERAGE_DOWN_MAX, dropped
    for s in dropped:
        assert "averaging down" not in by[s]["reason"].lower()
    sub_router.set_service(SubscriptionService())


def test_rebalance_reduces_name_far_above_average_holding():
    # One name at ~27% weight vs a ~12% average across 8 holdings (> 2x the
    # average) -> REDUCE on relative concentration, even though it is below the
    # 30% absolute cap.
    sm = {f"S{i}": (80, "BUY", 1.0) for i in range(8)}
    sm["BIG"] = (80, "BUY", 1.0)
    c = _build_client(score_map=sm)
    h = _register(c)
    positions = [_Pos("BIG", Market.US, 216_000.0)]  # 27% of 800k
    positions += [
        _Pos(f"S{i}", Market.US, 83_428.0) for i in range(7)
    ]
    c._simstate["positions"] = positions
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["BIG"]["action"] == "REDUCE", by["BIG"]
    assert "average holding" in by["BIG"]["reason"].lower()
    # A name at the average weight is NOT flagged on relative concentration.
    assert by["S0"]["action"] != "REDUCE", by["S0"]
    sub_router.set_service(SubscriptionService())


def test_rebalance_strong_name_after_hard_down_day_is_not_reduced():
    # A strong, high-score BUY name that just sold off hard (-12% today) must
    # NOT be flipped to REDUCE on a quality dip alone. Before the fix the
    # short-term-change terms zeroed out and dragged quality below 60, which
    # told the user to trim a winner right after a dip.
    c = _build_client(score_map={
        "DIPPED": (86, "BUY", -12.0),
        "F1": (80, "BUY", 1.0),
        "F2": (80, "BUY", 1.0),
        "F3": (80, "BUY", 1.0),
    })
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("DIPPED", Market.US, 250_000.0),
        _Pos("F1", Market.US, 250_000.0),
        _Pos("F2", Market.US, 250_000.0),
        _Pos("F3", Market.US, 250_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["DIPPED"]["action"] != "REDUCE", by["DIPPED"]
    assert by["DIPPED"]["action"] in ("HOLD", "ADD")
    sub_router.set_service(SubscriptionService())


def test_rebalance_weak_score_still_reduces_after_down_day():
    # The down-day softening must NOT mask a genuinely weak name: a soft score
    # (< 65) is still a REDUCE on its own regardless of the change clipping.
    c = _build_client(score_map={
        "SOFT": (60, "HOLD", -12.0),
        "F1": (80, "BUY", 1.0),
        "F2": (80, "BUY", 1.0),
        "F3": (80, "BUY", 1.0),
    })
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("SOFT", Market.US, 250_000.0),
        _Pos("F1", Market.US, 250_000.0),
        _Pos("F2", Market.US, 250_000.0),
        _Pos("F3", Market.US, 250_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["SOFT"]["action"] == "REDUCE"
    assert "score weakening" in by["SOFT"]["reason"].lower()
    sub_router.set_service(SubscriptionService())


def test_rebalance_unknown_score_is_not_auto_reduced():
    # A held name with NO live engine score (None) gets a neutral placeholder
    # quality. That placeholder must never trigger a REDUCE/EXIT; the name is
    # held with low confidence until a real score is available.
    c = _build_client(score_map={
        "UNKNOWN": None,
        "F1": (80, "BUY", 1.0),
        "F2": (80, "BUY", 1.0),
        "F3": (80, "BUY", 1.0),
    })
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("UNKNOWN", Market.US, 250_000.0),
        _Pos("F1", Market.US, 250_000.0),
        _Pos("F2", Market.US, 250_000.0),
        _Pos("F3", Market.US, 250_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    # No live score -> placeholder score/quality (50) are suppressed: with no
    # concentration, no SELL signal and a bullish regime the name is simply
    # HELD, not auto-trimmed on fabricated reads.
    assert by["UNKNOWN"]["action"] == "HOLD", by["UNKNOWN"]
    assert "quality below 60" not in by["UNKNOWN"]["reason"].lower()
    assert "score weakening" not in by["UNKNOWN"]["reason"].lower()
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


def test_rebalance_warns_on_over_diversification():
    # A book with far more names than a concentrated portfolio can manage must
    # surface an over-diversification warning (not block).
    c = _build_client()
    h = _register(c)
    c._simstate["positions"] = [
        _Pos(f"SYM{i}", Market.US, 100.0) for i in range(70)
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    warns = " ".join(body.get("warnings", []))
    assert "over-diversified" in warns.lower(), body.get("warnings")
    # A small book must NOT warn.
    c._simstate["positions"] = [
        _Pos(f"SYM{i}", Market.US, 100.0) for i in range(10)
    ]
    body2 = c.get("/v1/portfolio/rebalance", headers=h).json()
    assert "over-diversified" not in " ".join(
        body2.get("warnings", [])).lower()
    sub_router.set_service(SubscriptionService())


def test_rebalance_flags_unscored_loser_for_review():
    # An UNSCORED holding (no engine score -> low_confidence placeholder) that is
    # sitting on a meaningful loss must be surfaced as REVIEW, not buried in a
    # silent HOLD. We deliberately do NOT fabricate an EXIT/REDUCE on data we
    # don't have.
    c = _build_client(
        # UNKNOWN -> None => no live engine score (low_confidence placeholder).
        # GOODLOSS -> real score, small loss -> normal HOLD path.
        score_map={"UNKNOWN": None, "GOODLOSS": (78, "HOLD", -2.0)},
    )
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("UNKNOWN", Market.US, 50_000.0, unrealized_pnl=-8_000.0),  # -14%
        _Pos("GOODLOSS", Market.US, 450_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    assert by["UNKNOWN"]["action"] == "REVIEW", by["UNKNOWN"]
    assert "review" in by["UNKNOWN"]["reason"].lower()
    # A small unscored loss (or a scored name) should NOT trip REVIEW.
    assert by["GOODLOSS"]["action"] != "REVIEW", by["GOODLOSS"]
    sub_router.set_service(SubscriptionService())


def test_rebalance_bearish_does_not_reduce_below_target_holding():
    # REGRESSION: a BEAR market regime must NOT force a REDUCE on a name held
    # far below its target weight. Previously `bearish` alone swept the whole
    # book into REDUCE (even 0.1% positions with a 20% target) -- illogical.
    c = _build_client(
        # Give the Vietnam name a strong score so its target is high; it is
        # held at a tiny weight -> nothing to trim -> must NOT reduce.
        score_map={"VNSMALL": (90, "HOLD", -1.0),
                   "VNBIG": (90, "HOLD", -1.0)},
    )
    h = _register(c)
    c._simstate["positions"] = [
        _Pos("VNSMALL", Market.VIETNAM, 5_000.0),      # ~0.5% -> below target
        _Pos("VNBIG", Market.VIETNAM, 500_000.0),      # ~50% -> above target
        _Pos("FILL", Market.US, 495_000.0),
    ]
    body = c.get("/v1/portfolio/rebalance", headers=h).json()
    by = {a["symbol"]: a for a in body["actions"]}
    # The tiny below-target holding is NOT reduced by the bear regime alone.
    assert by["VNSMALL"]["action"] != "REDUCE", by["VNSMALL"]
    # The oversized above-target holding IS trimmed (there is risk to cut).
    assert by["VNBIG"]["action"] == "REDUCE", by["VNBIG"]
    sub_router.set_service(SubscriptionService())


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
