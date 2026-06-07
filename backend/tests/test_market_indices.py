"""Tests for the Dashboard market-index endpoint and service.

Yahoo is mocked via an injected fetcher (no network). Covers symbol mapping,
the four expected indices, successful fetch, a safe unavailable response on
fetch failure (never fabricated values), and the 5-minute cache.
"""

from __future__ import annotations

from datetime import datetime

import numpy as np
import pandas as pd
import pytest
from fastapi.testclient import TestClient
from zoneinfo import ZoneInfo

from app import main
from app.market import INDEX_BY_MARKET, MarketIndicesService
from app.models import Market


# --------------------------------------------------------------------------- #
# Symbol mapping                                                              #
# --------------------------------------------------------------------------- #
def test_index_symbol_mapping_is_correct():
    assert INDEX_BY_MARKET[Market.IDX].symbol == "^JKSE"
    assert INDEX_BY_MARKET[Market.IDX].name == "IHSG"
    assert INDEX_BY_MARKET[Market.HKEX].symbol == "^HSI"
    assert INDEX_BY_MARKET[Market.HKEX].name == "Hang Seng"
    assert INDEX_BY_MARKET[Market.KOSPI].symbol == "^KS11"
    assert INDEX_BY_MARKET[Market.KOSPI].name == "KOSPI Composite"
    assert INDEX_BY_MARKET[Market.KOSDAQ].symbol == "^KQ11"
    assert INDEX_BY_MARKET[Market.KOSDAQ].name == "KOSDAQ Composite"


# --------------------------------------------------------------------------- #
# Fetcher fakes                                                               #
# --------------------------------------------------------------------------- #
def _ohlcv(closes):
    """Build a minimal OHLCV frame with the given close series."""
    n = len(closes)
    idx = pd.date_range("2026-06-01", periods=n, freq="D")
    return pd.DataFrame(
        {
            "Open": closes,
            "High": [c * 1.01 for c in closes],
            "Low": [c * 0.99 for c in closes],
            "Close": closes,
            "Volume": [1000] * n,
        },
        index=idx,
    )


# Distinct last/prev closes per index so we can assert the right symbol mapped.
_PRICES = {
    "^JKSE": [7000.0, 7100.0],   # +100 / +1.4286%
    "^HSI": [19000.0, 19190.0],  # +190 / +1.0%
    "^KS11": [2600.0, 2626.0],   # +26 / +1.0%
    "^KQ11": [850.0, 858.5],     # +8.5 / +1.0%
}


def _fake_ok_fetch(ticker, period="5d", interval="1d"):
    if ticker not in _PRICES:
        raise ValueError(f"unexpected ticker {ticker}")
    return _ohlcv(_PRICES[ticker])


def _close_only(closes):
    """Frame with ONLY a Close column (no Volume / OHLC) -> index-like."""
    idx = pd.date_range("2026-06-01", periods=len(closes), freq="D")
    return pd.DataFrame({"Close": closes}, index=idx)


def _fake_fail_fetch(ticker, period="5d", interval="1d"):
    raise RuntimeError("yahoo unavailable / 429")


def _closed_now(market):
    # Sunday in each market timezone -> always CLOSED, deterministic.
    return datetime(2026, 6, 7, 12, 0, tzinfo=ZoneInfo("Asia/Jakarta"))


# --------------------------------------------------------------------------- #
# Service-level                                                               #
# --------------------------------------------------------------------------- #
def test_service_returns_all_four_indices():
    svc = MarketIndicesService(fetcher=_fake_ok_fetch, now_provider=_closed_now)
    quotes = svc.get_indices()
    by_market = {q.market: q for q in quotes}
    assert set(by_market) == {
        Market.IDX, Market.HKEX, Market.KOSPI, Market.KOSDAQ
    }
    # IHSG / Hang Seng / KOSPI / KOSDAQ present with the right symbols.
    assert by_market[Market.IDX].symbol == "^JKSE"
    assert by_market[Market.IDX].name == "IHSG"
    assert by_market[Market.HKEX].name == "Hang Seng"
    assert by_market[Market.KOSPI].name == "KOSPI Composite"
    assert by_market[Market.KOSDAQ].name == "KOSDAQ Composite"


def test_service_computes_price_and_change():
    svc = MarketIndicesService(fetcher=_fake_ok_fetch, now_provider=_closed_now)
    q = {q.market: q for q in svc.get_indices()}[Market.IDX]
    assert q.available is True
    assert q.price == 7100.0
    assert q.change == 100.0
    assert q.change_percent == pytest.approx(1.43, abs=0.01)
    assert q.currency == "IDR"
    assert q.status == "CLOSED"
    assert q.updated_at  # ISO timestamp present


def test_service_failure_is_safe_unavailable_not_fake():
    svc = MarketIndicesService(
        fetcher=_fake_fail_fetch, now_provider=_closed_now
    )
    for q in svc.get_indices():
        assert q.available is False
        assert q.price is None
        assert q.change is None
        assert q.change_percent is None
        # Status + identity still reported; numbers never fabricated.
        assert q.status in ("OPEN", "CLOSED")
        assert q.symbol.startswith("^")


def test_empty_frame_is_unavailable():
    def empty_fetch(ticker, period="5d", interval="1d"):
        return pd.DataFrame()

    svc = MarketIndicesService(fetcher=empty_fetch, now_provider=_closed_now)
    assert all(q.available is False and q.price is None
               for q in svc.get_indices())


# --------------------------------------------------------------------------- #
# Index tolerance: Close only, single row, NaN latest                         #
# --------------------------------------------------------------------------- #
def test_close_only_frame_without_volume_is_available():
    # Yahoo index frames often lack Volume; Close alone must be enough.
    def fetch(ticker, period="5d", interval="1d"):
        return _close_only(_PRICES[ticker])

    svc = MarketIndicesService(fetcher=fetch, now_provider=_closed_now)
    q = {q.market: q for q in svc.get_indices()}[Market.IDX]
    assert q.available is True
    assert q.price == 7100.0
    assert q.change == 100.0
    assert q.change_percent == pytest.approx(1.43, abs=0.01)


def test_single_close_row_is_available_with_null_change():
    def fetch(ticker, period="5d", interval="1d"):
        return _close_only([7100.0])

    svc = MarketIndicesService(fetcher=fetch, now_provider=_closed_now)
    q = {q.market: q for q in svc.get_indices()}[Market.IDX]
    assert q.available is True
    assert q.price == 7100.0
    assert q.change is None
    assert q.change_percent is None


def test_nan_latest_close_falls_back_to_last_valid():
    # Latest row NaN -> use the last valid Close (7100), change vs prior 7000.
    def fetch(ticker, period="5d", interval="1d"):
        return _close_only([7000.0, 7100.0, np.nan])

    svc = MarketIndicesService(fetcher=fetch, now_provider=_closed_now)
    q = {q.market: q for q in svc.get_indices()}[Market.IDX]
    assert q.available is True
    assert q.price == 7100.0
    assert q.change == 100.0


def test_index_fetch_default_requires_only_close(monkeypatch):
    # The default index fetcher must NOT reject a Close-only frame the way the
    # strict engine _yf_fetch would (that strictness caused the IHSG bug).
    import app.market.service as svc_mod

    def fake_download(ticker, **kwargs):
        return _close_only([7000.0, 7100.0])

    monkeypatch.setattr("yfinance.download", fake_download)
    monkeypatch.setattr(svc_mod, "_impersonating_session", lambda: None)
    df = svc_mod._index_fetch("^JKSE")
    assert "Close" in df.columns
    assert "Volume" not in df.columns  # tolerated, not required
    price, change, _ = MarketIndicesService._extract(df)
    assert price == 7100.0 and change == 100.0


def test_cache_avoids_repeated_fetches():
    calls = {"n": 0}

    def counting_fetch(ticker, period="5d", interval="1d"):
        calls["n"] += 1
        return _ohlcv(_PRICES[ticker])

    t = {"now": 1000.0}
    svc = MarketIndicesService(
        fetcher=counting_fetch,
        ttl_seconds=300,
        clock=lambda: t["now"],
        now_provider=_closed_now,
    )
    svc.get_indices()
    assert calls["n"] == 4  # one per index
    # Within TTL: served from cache, no new fetches.
    svc.get_indices()
    assert calls["n"] == 4
    # After TTL expiry: refetched.
    t["now"] = 1000.0 + 301
    svc.get_indices()
    assert calls["n"] == 8


def test_open_status_when_market_in_session():
    def open_now(market):
        # A weekday at 10:00 local -> within the 09-16 session window.
        return datetime(2026, 6, 8, 10, 0, tzinfo=ZoneInfo("Asia/Jakarta"))

    svc = MarketIndicesService(fetcher=_fake_ok_fetch, now_provider=open_now)
    q = {q.market: q for q in svc.get_indices()}[Market.IDX]
    assert q.status == "OPEN"


# --------------------------------------------------------------------------- #
# API-level                                                                   #
# --------------------------------------------------------------------------- #
@pytest.fixture()
def client_with(monkeypatch):
    def install(fetcher, now_provider=_closed_now):
        svc = MarketIndicesService(fetcher=fetcher, now_provider=now_provider)
        main.set_market_indices_service(svc)
        return TestClient(main.app)

    yield install
    # Reset to a default service after each test.
    main.set_market_indices_service(MarketIndicesService())


def test_api_returns_four_named_indices(client_with):
    client = client_with(_fake_ok_fetch)
    r = client.get("/v1/market/indices")
    assert r.status_code == 200
    indices = r.json()["indices"]
    assert len(indices) == 4
    names = {i["name"] for i in indices}
    assert names == {"IHSG", "Hang Seng", "KOSPI Composite", "KOSDAQ Composite"}
    symbols = {i["symbol"] for i in indices}
    assert symbols == {"^JKSE", "^HSI", "^KS11", "^KQ11"}
    # Each entry carries the required shape.
    for i in indices:
        assert set(i) >= {
            "symbol", "market", "name", "price", "change",
            "change_percent", "currency", "status", "updated_at",
        }


def test_api_success_has_real_numbers(client_with):
    client = client_with(_fake_ok_fetch)
    ihsg = next(
        i for i in client.get("/v1/market/indices").json()["indices"]
        if i["symbol"] == "^JKSE"
    )
    assert ihsg["price"] == 7100.0
    assert ihsg["change"] == 100.0
    assert ihsg["available"] is True


def test_api_ihsg_available_when_jkse_has_close_only(client_with):
    # Endpoint contract: IHSG (^JKSE) must be available=true when only Close
    # exists (no Volume) -- the exact case that previously showed unavailable.
    def fetch(ticker, period="5d", interval="1d"):
        return _close_only(_PRICES[ticker])

    client = client_with(fetch)
    ihsg = next(
        i for i in client.get("/v1/market/indices").json()["indices"]
        if i["symbol"] == "^JKSE"
    )
    assert ihsg["available"] is True
    assert ihsg["price"] == 7100.0
    assert ihsg["name"] == "IHSG"


def test_api_failure_reports_unavailable_not_fake(client_with):
    client = client_with(_fake_fail_fetch)
    indices = client.get("/v1/market/indices").json()["indices"]
    assert len(indices) == 4
    for i in indices:
        assert i["available"] is False
        assert i["price"] is None
        assert i["change"] is None
        assert i["change_percent"] is None
