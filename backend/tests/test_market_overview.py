"""Tests for the Dashboard Market Overview endpoint and aggregation.

The universe screen is injected (no network): we feed a fixed ScreenerResult
and assert breadth, top mover, total value traded, foreign-flow handling, the
5-minute cache, and the safe-unavailable path (never fabricated values).
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import main
from app.market import MarketOverviewService
from app.models import Market, ScreenerMatch, ScreenerResult


def _match(symbol, change_percent, value_traded, price=100.0, name=""):
    return ScreenerMatch(
        symbol=symbol,
        name=name or symbol,
        score=50.0,
        signal="HOLD",
        price=price,
        change_percent=change_percent,
        categories=[],
        value_traded=value_traded,
    )


def _universe(matches, status="CLOSED"):
    return ScreenerResult(
        market=Market.IDX,
        matches=matches,
        generated_at="2026-06-08T00:00:00Z",
        total_count=len(matches),
        returned_count=len(matches),
        market_status=status,
    )


_SAMPLE = [
    _match("AAA", 5.0, 1_000.0, price=1000.0),    # top gainer
    _match("BBB", 1.2, 2_000.0, price=200.0),
    _match("CCC", 0.0, 500.0, price=50.0),         # unchanged
    _match("DDD", -2.0, 3_000.0, price=300.0),
    _match("EEE", -7.5, 4_000.0, price=400.0),     # top loser
]


def _fixed_screen(result):
    def run(market):
        return result
    return run


# --------------------------------------------------------------------------- #
# Aggregation                                                                 #
# --------------------------------------------------------------------------- #
def test_breadth_counts():
    svc = MarketOverviewService(_fixed_screen(_universe(_SAMPLE)))
    ov = svc.get(Market.IDX)
    assert ov.available is True
    assert ov.advances == 2
    assert ov.declines == 2
    assert ov.unchanged == 1
    assert ov.total_symbols == 5


def test_top_gainer_and_loser():
    svc = MarketOverviewService(_fixed_screen(_universe(_SAMPLE)))
    ov = svc.get(Market.IDX)
    assert ov.top_gainer.symbol == "AAA"
    assert ov.top_gainer.change_percent == 5.0
    assert ov.top_loser.symbol == "EEE"
    assert ov.top_loser.change_percent == -7.5


def test_total_value_traded_is_sum():
    svc = MarketOverviewService(_fixed_screen(_universe(_SAMPLE)))
    ov = svc.get(Market.IDX)
    assert ov.total_value_traded == pytest.approx(10_500.0)
    assert ov.currency == "IDR"


def test_idx_has_foreign_flow_row_unavailable():
    svc = MarketOverviewService(_fixed_screen(_universe(_SAMPLE)))
    ov = svc.get(Market.IDX)
    # IDX surfaces the row, but with no real source it is unavailable (no mock).
    assert ov.foreign_flow is not None
    assert ov.foreign_flow.available is False
    assert ov.foreign_flow.net_value is None


def test_non_idx_has_no_foreign_flow():
    res = ScreenerResult(
        market=Market.HKEX,
        matches=_SAMPLE,
        generated_at="2026-06-08T00:00:00Z",
        market_status="CLOSED",
    )
    svc = MarketOverviewService(_fixed_screen(res))
    ov = svc.get(Market.HKEX)
    assert ov.foreign_flow is None
    assert ov.currency == "HKD"


# --------------------------------------------------------------------------- #
# Safe unavailable (never fabricated)                                         #
# --------------------------------------------------------------------------- #
def test_screen_failure_is_safe_unavailable():
    def boom(market):
        raise RuntimeError("screen failed")

    svc = MarketOverviewService(boom)
    ov = svc.get(Market.IDX)
    assert ov.available is False
    assert ov.advances is None
    assert ov.declines is None
    assert ov.unchanged is None
    assert ov.total_value_traded is None
    assert ov.top_gainer is None
    assert ov.top_loser is None
    # IDX still shows the (unavailable) foreign-flow row.
    assert ov.foreign_flow is not None and ov.foreign_flow.available is False


def test_empty_universe_is_unavailable():
    svc = MarketOverviewService(_fixed_screen(_universe([])))
    ov = svc.get(Market.IDX)
    assert ov.available is False
    assert ov.total_value_traded is None


# --------------------------------------------------------------------------- #
# Cache                                                                       #
# --------------------------------------------------------------------------- #
def test_cache_avoids_repeated_screens():
    calls = {"n": 0}

    def counting(market):
        calls["n"] += 1
        return _universe(_SAMPLE)

    t = {"now": 1000.0}
    # TTL-isolation test: disable the data-freshness probe so only the time
    # TTL governs caching here (the probe is covered by dedicated tests).
    svc = MarketOverviewService(
        counting, ttl_seconds=300, clock=lambda: t["now"],
        latest_data_timestamp=None,
    )
    svc.get(Market.IDX)
    svc.get(Market.IDX)
    assert calls["n"] == 1  # served from cache within TTL
    t["now"] = 1000.0 + 301
    svc.get(Market.IDX)
    assert calls["n"] == 2  # refetched after TTL


def test_cache_is_per_market():
    calls = {"n": 0}

    def counting(market):
        calls["n"] += 1
        return _universe(_SAMPLE)

    svc = MarketOverviewService(counting)
    svc.get(Market.IDX)
    svc.get(Market.HKEX)
    assert calls["n"] == 2  # different markets are cached separately


# --------------------------------------------------------------------------- #
# API                                                                         #
# --------------------------------------------------------------------------- #
@pytest.fixture()
def client_with(monkeypatch):
    def install(run_screen):
        svc = MarketOverviewService(run_screen)
        main.set_market_overview_service(svc)
        return TestClient(main.app)

    yield install
    main.set_market_overview_service(
        MarketOverviewService(main._overview_universe)
    )


def test_api_overview_shape(client_with):
    client = client_with(_fixed_screen(_universe(_SAMPLE)))
    r = client.get("/v1/market/overview/IDX")
    assert r.status_code == 200
    body = r.json()
    assert body["available"] is True
    assert body["market"] == "IDX"
    assert body["breadth"] == {
        "advances": 2, "declines": 2, "unchanged": 1, "total": 5,
    }
    assert body["total_value_traded"] == pytest.approx(10_500.0)
    assert body["top_gainer"]["symbol"] == "AAA"
    assert body["top_loser"]["symbol"] == "EEE"
    assert body["foreign_flow"]["available"] is False
    assert "updated_at" in body


def test_api_unknown_market_404(client_with):
    client = client_with(_fixed_screen(_universe(_SAMPLE)))
    r = client.get("/v1/market/overview/NOPE")
    assert r.status_code == 404


def test_api_failure_reports_unavailable(client_with):
    def boom(market):
        raise RuntimeError("down")

    client = client_with(boom)
    body = client.get("/v1/market/overview/IDX").json()
    assert body["available"] is False
    assert body["breadth"]["advances"] is None
    assert body["total_value_traded"] is None
    assert body["top_gainer"] is None
