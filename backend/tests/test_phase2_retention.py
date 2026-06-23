"""Phase 2 (Retention & differentiation) API + service tests.

Covers, end-to-end with real JWT auth and injected in-memory services:
  * AI Morning Brief (/v1/morning-brief/{market}) + once-per-session cache.
  * AI Portfolio Manager (/v1/portfolio/manager) recommendation rules.
  * Portfolio Journal (/v1/journal, /v1/journal/stats) + buy/sell hook.
  * Notification Engine (/v1/notifications, /read) generation + dedup.
  * Community demand analytics (/v1/analytics/demand) Most Requested Features.

All rule-based, simulated only, no broker contact.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.cache_layer.cache_manager import CacheManager as _CacheManager
from app.analytics import router as analytics_router  # noqa: F401
from app.journal import router as journal_router
from app.journal.service import JournalService
from app.journal.store import SqliteJournalStore
from app.models import Market, ScreenerCategory, ScreenerMatch, ScreenerResult
from app.morning_brief import router as brief_router
from app.morning_brief.service import MorningBriefService
from app.notifications import router as notif_router
from app.notifications.models import (
    TYPE_DAILY_PICK,
    TYPE_ELITE_OPPORTUNITY,
    TYPE_MULTIBAGGER,
    TYPE_PORTFOLIO_WARNING,
)
from app.notifications.service import NotificationService
from app.notifications.store import SqliteNotificationStore
from app.portfolio_health import router as health_router
from app.portfolio_health.service import PortfolioHealthService
from app.portfolio_manager import router as pm_router
from app.portfolio_manager.service import PortfolioManagerService
from app.radar import router as radar_router
from app.radar.service import RadarService
from app.simulation import router as sim_router
from app.market_session import MarketSessionState
from app.simulation.service import SimulationService
from app.simulation.store import SimulationStore
from app.subscription import router as sub_router
from app.subscription.service import SubscriptionService
from app.subscription.store import SqliteSubscriptionStore


# --- fakes ------------------------------------------------------------------
def _match(symbol, score, change, value, signal="BUY", cats=None):
    return ScreenerMatch(
        symbol=symbol, name=symbol, score=score, signal=signal, price=100.0,
        change_percent=change, categories=cats or [], value_traded=value,
    )


def _us():
    return [
        _match("NVDA", 94, 6.0, 8e9, cats=[ScreenerCategory.bullish]),
        _match("PLTR", 91, 5.0, 5e9,
               cats=[ScreenerCategory.turnaround_multibagger]),
        _match("AAPL", 88, 2.0, 4e9),
        _match("META", 60, 0.2, 5e8),
    ]


def _idx():
    return [
        _match("MPMX", 92, 4.0, 2e9,
               cats=[ScreenerCategory.turnaround_multibagger]),
        _match("BBCA", 90, 3.0, 2e9, cats=[ScreenerCategory.bullish]),
        _match("TPIA", 63, -1.0, 8e8, signal="HOLD"),
    ]


def _provider(market, limit=50, min_score=0.0, min_value_traded=0.0):
    data = {Market.US: _us(), Market.IDX: _idx()}.get(market, [])
    return ScreenerResult(market=market, matches=data[:limit],
                          generated_at="2026-06-09T00:00:00Z")


class _Pos:
    def __init__(self, symbol, market, market_value):
        self.symbol = symbol
        self.market = market
        self.quantity = 10.0
        self.market_value = market_value


class _Acct:
    def __init__(self, cash, equity):
        self.cash = cash
        self.equity = equity


def _build_client():
    """A preview-mode client with all Phase-2 services injected (in-memory)."""
    sub = SubscriptionService(
        store=SqliteSubscriptionStore(":memory:"), preview_mode=True
    )
    sub_router.set_service(sub)

    _cache = _CacheManager()
    radar = RadarService(_provider, markets=[Market.US, Market.IDX],
                         cache=_cache)
    radar_router.set_service(radar)

    state = {"positions": [], "account": _Acct(1_000_000.0, 1_000_000.0)}
    health = PortfolioHealthService(
        positions_provider=lambda uid: state["positions"],
        score_provider=lambda s, m: _match(s, 90, 2.0, 3e9),
    )
    health_router.set_service(health)

    brief_router.set_service(MorningBriefService(radar=radar, cache=_cache))

    journal_store = SqliteJournalStore(":memory:")
    journal = JournalService(
        store=journal_store,
        score_provider=lambda s, m: _match(s, 88, 2.0, 3e9),
        health_service=health,
        radar_service=radar,
    )
    journal_router.set_service(journal)

    # In-memory simulation (fake prices, no network) + journal trade hook.
    sim = SimulationService(
        price_provider=lambda s, m: 100.0,
        store=SimulationStore(":memory:"),
        # Force OPEN so MARKET orders fill immediately (and fire the journal
        # trade hook) regardless of wall-clock market hours.
        session_state_provider=lambda m: MarketSessionState.OPEN,
    )
    sim_router.set_service(sim)
    sim_router.set_trade_hook(
        lambda uid, symbol, market, side, qty, price: journal.on_trade(
            uid, symbol, market, side, qty, price
        )
    )

    def _snapshots(uid):
        return {
            (e.symbol, e.market): e.score
            for e in journal_store.list_entries(uid)
            if e.status == "OPEN" and e.score > 0
        }

    pm_router.set_service(PortfolioManagerService(
        health_service=health,
        positions_provider=lambda uid: state["positions"],
        account_provider=lambda uid: state["account"],
        snapshot_provider=_snapshots,
    ))

    notif_service = NotificationService(
        store=SqliteNotificationStore(":memory:"),
        radar_service=radar,
        health_service=health,
    )
    notif_router.set_service(notif_service)

    c = TestClient(main.app)
    c._simstate = state  # type: ignore[attr-defined]
    c._journal = journal  # type: ignore[attr-defined]
    c._notif = notif_service  # type: ignore[attr-defined]
    return c


@pytest.fixture()
def client():
    c = _build_client()
    yield c
    sub_router.set_service(SubscriptionService())
    sim_router.set_trade_hook(None)


def _register(c) -> dict:
    email = f"p2_{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/v1/auth/register",
               json={"email": email, "password": "Passw0rd!!"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def _uid(c, headers) -> int:
    return main._get_auth_service().verify_token(
        headers["Authorization"].split(" ", 1)[1]
    )


# === Phase A: AI Morning Brief =============================================
def test_morning_brief_requires_auth():
    c = TestClient(main.app)
    assert c.get("/v1/morning-brief/US").status_code == 401


def test_morning_brief_us(client):
    h = _register(client)
    r = client.get("/v1/morning-brief/US", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["market"] == "US"
    assert body["title"] == "AI Morning Brief"
    assert body["top_opportunity"]["symbol"] == "NVDA"
    assert body["top_opportunity"]["score"] == 94
    assert body["market_regime"] == "BULL"
    assert body["strongest_sector"]  # a label is set
    assert body["top_multibagger"] is not None


def test_morning_brief_unknown_market_404(client):
    h = _register(client)
    assert client.get("/v1/morning-brief/MARS", headers=h).status_code == 404


def test_morning_brief_cached_once_per_session(client):
    h = _register(client)
    first = client.get("/v1/morning-brief/IDX", headers=h).json()
    second = client.get("/v1/morning-brief/IDX", headers=h).json()
    assert first["cached"] is False
    assert second["cached"] is True
    # Same generated_at => served from cache, not recomputed.
    assert first["generated_at"] == second["generated_at"]


def test_morning_brief_records_demand_event(client):
    h = _register(client)
    client.get("/v1/morning-brief/US", headers=h)
    demand = client.get("/v1/subscription/demand", headers=h).json()
    metrics = {r["metric"] for r in demand["breakdown"]}
    assert "morning_brief_opened" in metrics


# === Phase D: AI Portfolio Manager =========================================
def test_portfolio_manager_empty(client):
    h = _register(client)
    r = client.get("/v1/portfolio/manager", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["simulated"] is True
    assert any(rec["kind"] == "health" for rec in body["recommendations"])


def test_portfolio_manager_concentration(client):
    h = _register(client)
    # One name = 63% of value -> elevated/critical concentration.
    client._simstate["positions"] = [
        _Pos("TPIA", Market.IDX, 6300.0),
        _Pos("BBCA", Market.IDX, 2000.0),
        _Pos("MPMX", Market.IDX, 1700.0),
    ]
    client._simstate["account"] = _Acct(100.0, 10100.0)
    r = client.get("/v1/portfolio/manager", headers=h)
    body = r.json()
    assert body["largest_position_pct"] >= 60.0
    msgs = " ".join(rec["message"] for rec in body["recommendations"])
    assert "TPIA represents 63% of portfolio value" in msgs
    # Cash below 5% -> a low-cash recommendation appears too.
    assert any(rec["kind"] == "cash_allocation"
               for rec in body["recommendations"])
    assert body["risk_level"] in ("HIGH", "MODERATE")


def test_portfolio_manager_strong_position(client):
    h = _register(client)
    client._simstate["positions"] = [
        _Pos("MPMX", Market.IDX, 3000.0),
        _Pos("BBCA", Market.IDX, 3000.0),
        _Pos("NVDA", Market.US, 3000.0),
    ]
    client._simstate["account"] = _Acct(200000.0, 209000.0)
    body = client.get("/v1/portfolio/manager", headers=h).json()
    assert any(rec["kind"] == "strong_position"
               for rec in body["recommendations"])


def test_portfolio_manager_records_event(client):
    h = _register(client)
    client.get("/v1/portfolio/manager", headers=h)
    demand = client.get("/v1/subscription/demand", headers=h).json()
    metrics = {r["metric"] for r in demand["breakdown"]}
    assert "portfolio_manager_opened" in metrics


# === Phase C: Portfolio Journal ============================================
def test_journal_buy_creates_open_entry(client):
    h = _register(client)
    # A simulated BUY routes through the order hook -> journal snapshot.
    r = client.post(
        "/v1/sim/order/place",
        json={"symbol": "MPMX", "market": "IDX", "side": "BUY",
              "quantity": 10},
        headers=h,
    )
    assert r.status_code == 200, r.text
    entries = client.get("/v1/journal", headers=h).json()["entries"]
    assert len(entries) == 1
    e = entries[0]
    assert e["symbol"] == "MPMX"
    assert e["status"] == "OPEN"
    assert e["score"] == 88
    assert e["quantity"] == 10


def test_journal_sell_closes_entry_with_return(client):
    h = _register(client)
    client.post("/v1/sim/order/place",
                json={"symbol": "MPMX", "market": "IDX", "side": "BUY",
                      "quantity": 10}, headers=h)
    # Manually close via the service (decoupled from sim price movement) so the
    # realized-return math is asserted deterministically.
    uid = _uid(client, h)
    open_entry = client._journal.entries(uid).entries[0]
    buy_price = open_entry.buy_price
    client._journal.on_trade(
        uid, "MPMX", Market.IDX, "SELL", 10, buy_price * 1.2
    )
    entries = client.get("/v1/journal", headers=h).json()["entries"]
    closed = [e for e in entries if e["status"] == "CLOSED"]
    assert len(closed) == 1
    assert round(closed[0]["realized_return"]) == 20  # +20%


def test_journal_stats(client):
    h = _register(client)
    uid = _uid(client, h)
    # Two winners, one loser (via the service hook directly).
    for sym, mult in [("MPMX", 1.30), ("BBCA", 1.10), ("TPIA", 0.80)]:
        client._journal.on_trade(uid, sym, Market.IDX, "BUY", 10, 100.0)
        client._journal.on_trade(uid, sym, Market.IDX, "SELL", 10, 100.0 * mult)
    stats = client.get("/v1/journal/stats", headers=h).json()
    assert stats["total_trades"] == 3
    assert round(stats["win_rate"]) == 67  # 2/3
    assert stats["best_trade"]["symbol"] == "MPMX"
    assert stats["worst_trade"]["symbol"] == "TPIA"
    assert stats["average_gain"] > 0
    assert stats["average_loss"] < 0


def test_journal_records_event(client):
    h = _register(client)
    client.get("/v1/journal", headers=h)
    demand = client.get("/v1/subscription/demand", headers=h).json()
    metrics = {r["metric"] for r in demand["breakdown"]}
    assert "journal_opened" in metrics


# === Phase B: Notifications ================================================
def test_notifications_generate_elite_and_multibagger(client):
    h = _register(client)
    r = client.get("/v1/notifications", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    types = {n["notification_type"] for n in body["notifications"]}
    assert TYPE_ELITE_OPPORTUNITY in types  # NVDA 94, PLTR 91, MPMX 92, BBCA 90
    assert TYPE_MULTIBAGGER in types
    assert TYPE_DAILY_PICK in types
    assert body["unread_count"] >= 1


def test_notifications_dedup_on_refresh(client):
    h = _register(client)
    first = client.get("/v1/notifications", headers=h).json()
    count1 = len(first["notifications"])
    second = client.get("/v1/notifications", headers=h).json()
    # No duplicates added on a second refresh in the same session.
    assert len(second["notifications"]) == count1


def test_notifications_health_drop_warning(client):
    h = _register(client)
    uid = _uid(client, h)
    # Seed a high last-seen health, then make health drop > 15.
    client._notif.set_last_health(uid, 90.0)
    client._simstate["positions"] = [_Pos("TPIA", Market.IDX, 1000.0)]
    # The injected score_provider returns 90, but a single weak/concentrated
    # holding lowers the computed health below 75 -> a drop warning.
    client._notif.refresh(uid)
    body = client.get("/v1/notifications", headers=h).json()
    types = {n["notification_type"] for n in body["notifications"]}
    assert TYPE_PORTFOLIO_WARNING in types


def test_notifications_mark_read(client):
    h = _register(client)
    client.get("/v1/notifications", headers=h)
    r = client.post("/v1/notifications/read", json={}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["unread_count"] == 0
    after = client.get("/v1/notifications", headers=h).json()
    # Re-fetching marks nothing new unread (dedup) -> still all read.
    assert after["unread_count"] == 0


def test_notifications_records_event(client):
    h = _register(client)
    client.get("/v1/notifications", headers=h)
    demand = client.get("/v1/subscription/demand", headers=h).json()
    metrics = {r["metric"] for r in demand["breakdown"]}
    assert "notification_opened" in metrics


# === Phase E: Community demand analytics ===================================
def test_analytics_demand_most_requested(client):
    h = _register(client)
    # Generate demand across several features.
    client.get("/v1/portfolio/manager", headers=h)
    client.get("/v1/portfolio/manager", headers=h)
    client.get("/v1/morning-brief/US", headers=h)
    client.get("/v1/journal", headers=h)
    client.get("/v1/radar/multibagger", headers=h)

    r = client.get("/v1/analytics/demand", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    feats = {f["feature"]: f["opens"] for f in body["most_requested_features"]}
    assert feats["AI Portfolio Manager"] >= 2
    assert "AI Morning Brief" in feats
    assert "Multibagger Finder" in feats
    # Sorted by opens descending.
    opens = [f["opens"] for f in body["most_requested_features"]]
    assert opens == sorted(opens, reverse=True)


def test_analytics_demand_requires_auth():
    c = TestClient(main.app)
    assert c.get("/v1/analytics/demand").status_code == 401
