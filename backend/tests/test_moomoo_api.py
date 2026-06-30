"""Guard-rail tests for the PRIVATE /v1/broker/moomoo/* live-trading bridge.

No OpenD / Moomoo SDK is required: a fake MoomooService is injected so only the
router gating + plumbing is exercised. Live order placement against a real
broker is NEVER triggered here.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.moomoo import router as moomoo_router
from app.moomoo.service import (
    MoomooAccount,
    MoomooError,
    MoomooOrderResult,
    MoomooPosition,
)

SECRET = "test-moomoo-secret"


class FakeMoomooService:
    """Stand-in for MoomooService that records calls and never touches OpenD.

    Honours the same notional-cap / confirm guard-rails the router relies on
    by delegating to the real preview/place logic where it is pure, but the
    network call (place_order) is replaced with an in-memory stub.
    """

    def __init__(self, cap: float = 1000.0):
        self.cap = cap
        self.placed = []
        import tempfile, os
        from app.moomoo.equity_tracker import EquityTracker
        self.equity_tracker = EquityTracker(
            os.path.join(tempfile.mkdtemp(), "eq.json")
        )

    def account(self):
        acct = MoomooAccount(5630.62, 4425.69, 4848.57, 1204.93, "USD")
        self.equity_tracker.record(acct.total_assets)
        return acct

    def positions(self):
        return [
            MoomooPosition("US.INTC", "INTC", 0.3, 0.3, 140.0, 134.0, -1.7, -4.0),
            MoomooPosition("US.ARM", "ARM", 0.1, 0.1, 442.8, 388.3, -5.4, -12.3),
        ]

    def _est(self, symbol, qty, price):
        if price and price > 0:
            return abs(qty) * price
        for p in self.positions():
            if p.symbol == symbol.split(".")[-1]:
                return abs(qty) * p.last_price
        return 0.0

    def preview(self, symbol, side, qty, order_type, price):
        code = symbol if symbol.startswith("US.") else f"US.{symbol.upper()}"
        otype = (order_type or "MARKET").upper()
        if otype not in ("MARKET", "LIMIT"):
            raise MoomooError("order_type must be MARKET or LIMIT.", 422)
        if otype == "LIMIT" and (price is None or price <= 0):
            raise MoomooError("LIMIT orders require a positive price.", 422)
        est = self._est(code, qty, price or 0.0)
        return {
            "code": code, "symbol": code.split(".")[1], "side": side.upper(),
            "order_type": otype, "quantity": float(qty),
            "price": float(price) if price else 0.0,
            "est_notional": round(est, 2), "max_notional": self.cap,
            "within_cap": est <= self.cap or est == 0.0, "live": True,
            "currency": "USD",
        }

    def place(self, symbol, side, qty, order_type, price, confirm,
              trade_pin=None, *, extended_hours=False):
        import os as _os
        # Record whether the caller asked for an extended/overnight order so
        # tests can assert the closed-market path used a resting LIMIT.
        self.last_extended = bool(extended_hours)
        if not confirm:
            raise MoomooError("Live order requires confirm=true after preview.", 428)
        # SKIP_UNLOCK mirrors the prod GUI-OpenD path (operator unlocks once);
        # the server-managed SL/TP monitor relies on it to sell without a PIN.
        skip = _os.environ.get("TRADEWIZZ_MOOMOO_SKIP_UNLOCK", "") in (
            "1", "true", "True"
        )
        if not skip and not (trade_pin or "").strip():
            raise MoomooError("Trade PIN is required to place a live order.", 428)
        pv = self.preview(symbol, side, qty, order_type, price)
        if not pv["within_cap"] and pv["est_notional"] > 0:
            raise MoomooError("exceeds the per-order cap", 403)
        self.placed.append(pv)
        return MoomooOrderResult(
            order_id="SIM-OID-1", code=pv["code"], side=pv["side"],
            order_type=pv["order_type"], qty=pv["quantity"], price=pv["price"],
            status="SUBMITTING", live=True,
        )

    def cancel(self, order_id):
        return {"order_id": order_id, "status": "CANCELLED", "live": True}

    def open_orders(self):
        from app.moomoo.service import MoomooOpenOrder
        return [
            MoomooOpenOrder(
                order_id="OID-1", code="US.INTC", symbol="INTC",
                side="BUY", qty=1.0, filled_qty=0.0, price=0.0,
                status="SUBMITTED",
            ),
        ]

    def manager_report(self):
        return {
            "risk_level": "MODERATE",
            "concentration_score": 80.0,
            "diversification_score": 20.0,
            "cash_pct": 78.6,
            "largest_position_pct": 20.0,
            "holdings_count": 2,
            "recommendations": [
                {"kind": "diversification", "severity": "warning",
                 "title": "Low diversification", "message": "x"},
            ],
            "live": True,
        }


@pytest.fixture()
def fake_svc(tmp_path, monkeypatch):
    svc = FakeMoomooService()
    moomoo_router.set_service(svc)
    # Isolate the server-managed SL/TP store on disk and reset the cached
    # monitor so each test gets a fresh, fake-backed bracket monitor.
    monkeypatch.setenv(
        "TRADEWIZZ_MOOMOO_SLTP_PATH", str(tmp_path / "sltp.json")
    )
    moomoo_router._sltp_monitor = None
    yield svc
    moomoo_router.set_service(None)
    moomoo_router._sltp_monitor = None


@pytest.fixture()
def client(monkeypatch, fake_svc):
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_SECRET", SECRET)
    c = TestClient(main.app)
    # Register an owner user and pin their uid into the allowlist.
    email = f"owner_{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/v1/auth/register", json={"email": email, "password": "Passw0rd!!"})
    assert r.status_code == 200, r.text
    token = r.json()["access_token"]
    uid = main._get_auth_service().verify_token(token)
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_OWNER_UIDS", str(uid))
    c._owner = {"Authorization": f"Bearer {token}", "X-Moomoo-Secret": SECRET}
    yield c


def test_bridge_disabled_without_secret(monkeypatch, fake_svc):
    monkeypatch.delenv("TRADEWIZZ_MOOMOO_SECRET", raising=False)
    c = TestClient(main.app)
    assert c.get("/v1/broker/moomoo/account").status_code == 503


def test_wrong_secret_is_forbidden(client):
    h = dict(client._owner)
    h["X-Moomoo-Secret"] = "nope"
    assert client.get("/v1/broker/moomoo/account", headers=h).status_code == 403


def test_missing_token_unauthorized(client):
    h = {"X-Moomoo-Secret": SECRET}
    assert client.get("/v1/broker/moomoo/account", headers=h).status_code == 401


def test_non_owner_forbidden(client, monkeypatch):
    # Move the allowlist away from this user's uid.
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_OWNER_UIDS", "999999")
    assert client.get("/v1/broker/moomoo/account",
                      headers=client._owner).status_code == 403


def test_account_history_records_real_equity(client):
    # Empty until the account is observed at least once.
    h0 = client.get("/v1/broker/moomoo/account/history",
                    headers=client._owner)
    assert h0.status_code == 200, h0.text
    assert h0.json()["points"] == []
    # Hitting /account records one real equity observation.
    client.get("/v1/broker/moomoo/account", headers=client._owner)
    h1 = client.get("/v1/broker/moomoo/account/history",
                    headers=client._owner)
    pts = h1.json()["points"]
    assert len(pts) == 1
    assert pts[0]["equity"] == 5630.62
    assert pts[0]["ts"] > 0


def test_account_history_requires_owner(client, monkeypatch):
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_OWNER_UIDS", "999999")
    r = client.get("/v1/broker/moomoo/account/history",
                   headers=client._owner)
    assert r.status_code == 403


def test_account_and_positions(client):
    a = client.get("/v1/broker/moomoo/account", headers=client._owner)
    assert a.status_code == 200, a.text
    assert a.json()["cash"] == 4425.69 and a.json()["live"] is True
    p = client.get("/v1/broker/moomoo/positions", headers=client._owner)
    assert p.status_code == 200
    syms = {x["symbol"] for x in p.json()["positions"]}
    assert {"INTC", "ARM"} <= syms


def test_open_orders_returns_pending(client):
    r = client.get("/v1/broker/moomoo/orders", headers=client._owner)
    assert r.status_code == 200, r.text
    orders = r.json()["orders"]
    assert len(orders) == 1
    o = orders[0]
    assert o["symbol"] == "INTC"
    assert o["side"] == "BUY"
    assert o["status"] == "SUBMITTED"
    assert r.json()["live"] is True


def test_open_orders_requires_owner(client, monkeypatch):
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_OWNER_UIDS", "999999")
    r = client.get("/v1/broker/moomoo/orders", headers=client._owner)
    assert r.status_code in (401, 403)


def test_preview_does_not_place(client, fake_svc):
    body = {"symbol": "INTC", "side": "BUY", "quantity": 1,
            "order_type": "LIMIT", "price": 100}
    r = client.post("/v1/broker/moomoo/order/preview", json=body,
                    headers=client._owner)
    assert r.status_code == 200, r.text
    assert r.json()["est_notional"] == 100.0
    assert r.json()["within_cap"] is True
    assert fake_svc.placed == []  # preview never places


def test_place_requires_confirm(client, fake_svc):
    body = {"symbol": "INTC", "side": "BUY", "quantity": 1,
            "order_type": "LIMIT", "price": 100, "confirm": False}
    r = client.post("/v1/broker/moomoo/order/place", json=body,
                    headers=client._owner)
    assert r.status_code == 428
    assert fake_svc.placed == []


def test_place_requires_pin(client, fake_svc):
    body = {"symbol": "INTC", "side": "BUY", "quantity": 1,
            "order_type": "LIMIT", "price": 100, "confirm": True}
    r = client.post("/v1/broker/moomoo/order/place", json=body,
                    headers=client._owner)
    assert r.status_code == 428  # confirm ok but no trade_pin
    assert fake_svc.placed == []


def test_place_with_confirm_succeeds(client, fake_svc):
    body = {"symbol": "INTC", "side": "BUY", "quantity": 1,
            "order_type": "LIMIT", "price": 100, "confirm": True,
            "trade_pin": "123456"}
    r = client.post("/v1/broker/moomoo/order/place", json=body,
                    headers=client._owner)
    assert r.status_code == 200, r.text
    assert r.json()["order_id"] == "SIM-OID-1"
    assert r.json()["status"] == "SUBMITTING"
    assert len(fake_svc.placed) == 1


def test_notional_cap_blocks_large_order(client, fake_svc):
    body = {"symbol": "INTC", "side": "BUY", "quantity": 100,
            "order_type": "LIMIT", "price": 100, "confirm": True,
            "trade_pin": "123456"}  # $10k > $1k
    r = client.post("/v1/broker/moomoo/order/place", json=body,
                    headers=client._owner)
    assert r.status_code == 403
    assert fake_svc.placed == []


def test_cancel(client):
    r = client.post("/v1/broker/moomoo/order/cancel/OID-9",
                    headers=client._owner)
    assert r.status_code == 200
    assert r.json()["status"] == "CANCELLED"


def test_preview_fractional_market_allowed():
    """Real MoomooService.preview accepts fractional qty for MARKET orders.
    A price is supplied so est_notional returns early WITHOUT touching OpenD
    (positions()), keeping the test hermetic."""
    from app.moomoo.service import MoomooService
    svc = MoomooService()
    # MARKET path with an explicit price avoids the positions() lookup.
    pv = svc.preview("INTC", "BUY", 0.001, "MARKET", 30.0)
    assert pv["quantity"] == 0.001
    assert pv["order_type"] == "MARKET"


def test_preview_fractional_limit_rejected():
    """Fractional qty on a LIMIT order is rejected (422), before any OpenD
    access."""
    from app.moomoo.service import MoomooService, MoomooError
    svc = MoomooService()
    try:
        svc.preview("INTC", "BUY", 0.5, "LIMIT", 30.0)
        assert False, "expected MoomooError"
    except MoomooError as e:
        assert e.status_code == 422


def test_manager_requires_owner(client):
    # No owner headers -> blocked.
    r = client.get("/v1/broker/moomoo/manager")
    assert r.status_code in (401, 403)


def test_manager_returns_report(client, fake_svc):
    r = client.get("/v1/broker/moomoo/manager", headers=client._owner)
    assert r.status_code == 200
    j = r.json()
    assert j["risk_level"] == "MODERATE"
    assert j["holdings_count"] == 2
    assert j["live"] is True
    assert any(x["kind"] == "diversification" for x in j["recommendations"])


def test_manager_report_allocation_math(monkeypatch):
    """Real MoomooService.manager_report allocation math, with account /
    positions stubbed so no OpenD is touched."""
    from app.moomoo.service import (
        MoomooService, MoomooAccount, MoomooPosition,
    )
    svc = MoomooService()
    # One name dominates -> critical concentration + HIGH risk.
    monkeypatch.setattr(
        svc, "account",
        lambda: MoomooAccount(1000.0, 50.0, 50.0, 950.0, "USD"),
    )
    monkeypatch.setattr(
        svc, "positions",
        lambda: [
            MoomooPosition("US.AAA", "AAA", 10.0, 10.0, 80.0, 90.0, 100.0, 0.12),
            MoomooPosition("US.BBB", "BBB", 1.0, 1.0, 50.0, 50.0, 0.0, 0.0),
        ],
    )
    rep = svc.manager_report()
    # AAA = 900 of 950 total = ~94.7% -> critical concentration, HIGH risk.
    assert rep["largest_position_pct"] > 90
    assert rep["risk_level"] == "HIGH"
    assert rep["holdings_count"] == 2
    assert any(x["kind"] == "concentration" and x["severity"] == "critical"
               for x in rep["recommendations"])


def _fake_score(symbol, market):
    """Deterministic ScreenerMatch so health/rebalance run without the engine."""
    from app.models import ScreenerMatch, Market
    base = {"INTC": 62.0, "ARM": 78.0}.get(symbol, 70.0)
    return ScreenerMatch(
        symbol=symbol, name=symbol, score=base, signal="HOLD",
        price=100.0, change_percent=1.2, categories=[],
        value_traded=5_000_000.0,
    )


def _wire_analytics(fake_svc):
    from app.moomoo.analytics import MoomooAnalytics
    moomoo_router.set_analytics(
        MoomooAnalytics(
            moomoo_service=fake_svc,
            score_provider=_fake_score,
            regime_provider=lambda market: "NEUTRAL",
        )
    )


def test_health_requires_owner(client):
    r = client.get("/v1/broker/moomoo/health")
    assert r.status_code in (401, 403)


def test_health_over_live_holdings(client, fake_svc):
    _wire_analytics(fake_svc)
    r = client.get("/v1/broker/moomoo/health", headers=client._owner)
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["simulated"] is False           # live holdings, not the sim
    assert 0 <= j["health_score"] <= 100
    assert "components" in j
    assert len(j["positions"]) == 2          # INTC + ARM
    moomoo_router.set_analytics(None)


def test_rebalance_over_live_holdings(client, fake_svc):
    _wire_analytics(fake_svc)
    r = client.get("/v1/broker/moomoo/rebalance", headers=client._owner)
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["simulated"] is False
    assert "actions" in j
    assert isinstance(j["actions"], list)
    moomoo_router.set_analytics(None)


# --- server-managed stop-loss / take-profit (bracket) -------------------- #
def test_brackets_require_owner(client):
    assert client.get("/v1/broker/moomoo/brackets").status_code in (401, 403)
    r = client.post(
        "/v1/broker/moomoo/brackets",
        json={"symbol": "INTC", "quantity": 1, "reference_price": 100},
    )
    assert r.status_code in (401, 403)


def test_attach_bracket_derives_levels(client, fake_svc):
    r = client.post(
        "/v1/broker/moomoo/brackets",
        json={"symbol": "INTC", "quantity": 0.3, "reference_price": 100.0},
        headers=client._owner,
    )
    assert r.status_code == 200, r.text
    b = r.json()
    # Default tight-stop swing plan: -1% / +3%.
    assert b["stop_pct"] == -1.0 and b["target_pct"] == 3.0
    assert b["stop_price"] == 99.0 and b["target_price"] == 103.0
    assert b["status"] == "ACTIVE"
    # It shows up in the list.
    lst = client.get("/v1/broker/moomoo/brackets", headers=client._owner)
    syms = [x["symbol"] for x in lst.json()["brackets"]]
    assert "INTC" in syms


def test_attach_bracket_validates_direction(client, fake_svc):
    # Positive stop_pct (above entry) is rejected.
    r = client.post(
        "/v1/broker/moomoo/brackets",
        json={"symbol": "INTC", "quantity": 1, "reference_price": 100,
              "stop_pct": 1.0, "target_pct": 3.0},
        headers=client._owner,
    )
    assert r.status_code == 422


def test_cancel_bracket(client, fake_svc):
    client.post(
        "/v1/broker/moomoo/brackets",
        json={"symbol": "INTC", "quantity": 1, "reference_price": 100},
        headers=client._owner,
    )
    r = client.delete(
        "/v1/broker/moomoo/brackets/INTC", headers=client._owner
    )
    assert r.status_code == 200
    assert r.json()["status"] == "CANCELLED"
    # No active bracket -> 404 on a second cancel.
    r2 = client.delete(
        "/v1/broker/moomoo/brackets/INTC", headers=client._owner
    )
    assert r2.status_code == 404


def test_check_triggers_stop_loss(client, fake_svc, monkeypatch):
    # The monitor sells on the SKIP_UNLOCK prod path (operator-unlocked OpenD).
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_SKIP_UNLOCK", "1")
    # Force the regular US session open so a touched level fires a live MARKET
    # sell (the closed-market path is covered by the tests below).
    from app.moomoo import sltp as _sltp
    monkeypatch.setattr(_sltp, "_us_session_open", lambda: True)
    # INTC fake position has last_price 134. A stop just above it must fire a
    # MARKET sell on the monitor tick, and the bracket leaves ACTIVE (OCO).
    client.post(
        "/v1/broker/moomoo/brackets",
        json={"symbol": "INTC", "quantity": 0.3, "reference_price": 140.0,
              "stop_pct": -3.0, "target_pct": 10.0},
        headers=client._owner,
    )
    # stop_price = 140 * 0.97 = 135.8 > last 134 -> stop is touched.
    before = len(fake_svc.placed)
    r = client.post(
        "/v1/broker/moomoo/brackets/check", headers=client._owner
    )
    assert r.status_code == 200, r.text
    assert len(fake_svc.placed) == before + 1
    sold = fake_svc.placed[-1]
    assert sold["side"] == "SELL" and sold["order_type"] == "MARKET"
    # Bracket is now terminal (TRIGGERED_STOP), not ACTIVE.
    states = {x["symbol"]: x["status"] for x in r.json()["brackets"]}
    assert states.get("INTC") == "TRIGGERED_STOP"


class _ClosedMarketFake:
    """Minimal moomoo service for the monitor's closed-market path.

    Holds one position and records every place() call so the test can assert
    the order style (LIMIT + extended) chosen when the regular session is
    closed. Quantity is parameterised so we can cover whole vs fractional lots.
    """

    def __init__(self, qty):
        self._qty = float(qty)
        self.placed = []
        self.last_extended = False

    def positions(self):
        # Touched stop: last 134 < stop_price 135.8 (ref 140, -3%).
        return [
            MoomooPosition(
                "US.WHL", "WHL", self._qty, self._qty, 140.0, 134.0, 0.0, 0.0
            )
        ]

    def place(self, symbol, side, qty, order_type, price, confirm,
              trade_pin=None, *, extended_hours=False):
        self.last_extended = bool(extended_hours)
        self.placed.append({
            "symbol": symbol, "side": side, "qty": qty,
            "order_type": order_type, "price": price,
            "extended": bool(extended_hours),
        })
        return MoomooOrderResult(
            order_id="SIM-OID-EXT", code=f"US.{symbol}", side=side,
            order_type=order_type, qty=qty, price=price or 0.0,
            status="SUBMITTING", live=True,
        )


def _closed_monitor(tmp_path, qty):
    from app.moomoo.sltp import SLTPMonitor, SLTPStore
    svc = _ClosedMarketFake(qty)
    mon = SLTPMonitor(svc, store=SLTPStore(str(tmp_path / "ext_sltp.json")))
    return svc, mon


def test_closed_market_whole_share_rests_pending_limit(tmp_path, monkeypatch):
    # Market closed + a whole-share lot: instead of failing a MARKET sell, the
    # monitor rests a LIMIT order for the extended/overnight session and the
    # bracket goes PENDING_EXT (not ERROR / ACTIVE-retry-forever).
    from app.moomoo import sltp as _sltp
    monkeypatch.setattr(_sltp, "_us_session_open", lambda: False)
    svc, mon = _closed_monitor(tmp_path, qty=3.0)
    mon.store.attach("WHL", 3.0, 140.0, stop_pct=-3.0, target_pct=10.0)

    actions = mon.tick()
    assert len(svc.placed) == 1
    sold = svc.placed[-1]
    assert sold["side"] == "SELL" and sold["order_type"] == "LIMIT"
    assert svc.last_extended is True
    states = {b.symbol: b.status for b in mon.store.list()}
    assert states.get("WHL") == "PENDING_EXT"
    assert actions and actions[0]["action"] == "pending_ext"


def test_closed_market_fractional_defers_to_regular_session(
    tmp_path, monkeypatch
):
    # Market closed + a fractional lot: Moomoo can't trade fractional outside
    # RTH, so the monitor places NO order and the bracket stays ACTIVE to fire
    # at the next regular open (no failed order).
    from app.moomoo import sltp as _sltp
    monkeypatch.setattr(_sltp, "_us_session_open", lambda: False)
    svc, mon = _closed_monitor(tmp_path, qty=0.3)
    mon.store.attach("WHL", 0.3, 140.0, stop_pct=-3.0, target_pct=10.0)

    actions = mon.tick()
    assert svc.placed == []  # nothing placed
    states = {b.symbol: b.status for b in mon.store.list()}
    assert states.get("WHL") == "ACTIVE"
    assert actions and actions[0]["action"] == "deferred"


def test_check_closes_bracket_when_position_gone(client, fake_svc):
    client.post(
        "/v1/broker/moomoo/brackets",
        json={"symbol": "NVDA", "quantity": 1, "reference_price": 100.0},
        headers=client._owner,
    )
    # NVDA is not in the fake positions list -> bracket retired, no sell.
    before = len(fake_svc.placed)
    r = client.post(
        "/v1/broker/moomoo/brackets/check", headers=client._owner
    )
    assert len(fake_svc.placed) == before
    states = {x["symbol"]: x["status"] for x in r.json()["brackets"]}
    assert states.get("NVDA") == "CLOSED_NO_POSITION"
