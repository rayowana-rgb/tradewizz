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
    # --- Global market expansion indices ---
    "^GSPC": [5000.0, 5050.0],     # S&P 500
    "^N225": [38000.0, 38380.0],   # Nikkei 225
    "^NSEI": [22000.0, 22220.0],   # Nifty 50
    "^VNINDEX": [1200.0, 1212.0],  # VN-Index
    "^STI": [3300.0, 3333.0],      # Straits Times
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
    # Original four plus the global-expansion markets.
    assert set(by_market) == {
        Market.IDX, Market.HKEX, Market.KOSPI, Market.KOSDAQ,
        Market.US, Market.JAPAN, Market.INDIA, Market.VIETNAM,
        Market.SINGAPORE,
    }
    # IHSG / Hang Seng / KOSPI / KOSDAQ present with the right symbols.
    assert by_market[Market.IDX].symbol == "^JKSE"
    assert by_market[Market.IDX].name == "IHSG"
    assert by_market[Market.HKEX].name == "Hang Seng"
    assert by_market[Market.KOSPI].name == "KOSPI Composite"
    assert by_market[Market.KOSDAQ].name == "KOSDAQ Composite"
    # New markets resolve to their index symbols.
    assert by_market[Market.US].symbol == "^GSPC"
    assert by_market[Market.JAPAN].symbol == "^N225"
    assert by_market[Market.INDIA].symbol == "^NSEI"
    assert by_market[Market.VIETNAM].symbol == "^VNINDEX"
    assert by_market[Market.SINGAPORE].symbol == "^STI"


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
    # Each fetchable index triggers a DAILY fetch plus a best-effort INTRADAY
    # fetch (used to surface today's level when the daily candle lags). Markets
    # with no working Yahoo symbol (e.g. Vietnam) skip the fetch entirely.
    from app.market.service import INDEX_SPECS
    n_indices = sum(1 for s in INDEX_SPECS if s.fetchable)
    per_refresh = n_indices * 2  # daily + intraday
    svc.get_indices()
    assert calls["n"] == per_refresh
    # Within TTL: served from cache, no new fetches.
    svc.get_indices()
    assert calls["n"] == per_refresh
    # After TTL expiry: refetched.
    t["now"] = 1000.0 + 301
    svc.get_indices()
    assert calls["n"] == per_refresh * 2


def test_intraday_overrides_stale_daily_candle():
    # The bug: after the session closes, Yahoo's DAILY candle still ends on the
    # PRIOR day, so Home showed yesterday's close. When a more-recent intraday
    # tick exists it must win, with change computed vs the last DAILY close.
    daily_idx = pd.date_range("2026-06-08", periods=3, freq="D")  # ..06-10
    daily = pd.DataFrame({"Close": [5800.0, 5850.0, 5886.0]}, index=daily_idx)
    # Intraday tick is on 2026-06-11 (newer than the last daily candle).
    intra_idx = pd.to_datetime(
        ["2026-06-11 08:58:00+00:00", "2026-06-11 09:00:00+00:00"]
    )
    intraday = pd.DataFrame({"Close": [6005.0, 6007.66]}, index=intra_idx)

    def fetch(ticker, period="5d", interval="1d"):
        if ticker != "^JKSE":
            raise ValueError(f"unexpected ticker {ticker}")
        return intraday if interval == "1m" else daily

    svc = MarketIndicesService(fetcher=fetch, now_provider=_closed_now)
    spec = INDEX_BY_MARKET[Market.IDX]
    q = svc._fetch_quote(spec)
    assert q.available is True
    assert q.price == 6007.66  # today's intraday level, not 5886 daily
    assert q.change == round(6007.66 - 5886.0, 2)  # vs last DAILY close
    assert q.change_percent == round((6007.66 - 5886.0) / 5886.0 * 100, 2)


def test_intraday_same_day_does_not_override_daily():
    # When the daily candle is already up to date (same trading day as the
    # intraday tick), the daily extraction stands -> no double counting.
    daily_idx = pd.date_range("2026-06-09", periods=2, freq="D")  # ..06-10
    daily = pd.DataFrame({"Close": [5850.0, 5886.0]}, index=daily_idx)
    intra_idx = pd.to_datetime(["2026-06-10 09:00:00+00:00"])  # same day
    intraday = pd.DataFrame({"Close": [5999.0]}, index=intra_idx)

    def fetch(ticker, period="5d", interval="1d"):
        return intraday if interval == "1m" else daily

    svc = MarketIndicesService(fetcher=fetch, now_provider=_closed_now)
    q = svc._fetch_quote(INDEX_BY_MARKET[Market.IDX])
    assert q.price == 5886.0  # daily last close, intraday ignored (same day)
    assert q.change == round(5886.0 - 5850.0, 2)


def test_intraday_failure_falls_back_to_daily():
    # Intraday is best-effort: if it raises, the daily quote is still served.
    daily = pd.DataFrame(
        {"Close": [5850.0, 5886.0]},
        index=pd.date_range("2026-06-09", periods=2, freq="D"),
    )

    def fetch(ticker, period="5d", interval="1d"):
        if interval == "1m":
            raise RuntimeError("intraday 429")
        return daily

    svc = MarketIndicesService(fetcher=fetch, now_provider=_closed_now)
    q = svc._fetch_quote(INDEX_BY_MARKET[Market.IDX])
    assert q.available is True
    assert q.price == 5886.0
    assert q.change == round(5886.0 - 5850.0, 2)


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
    assert len(indices) == len(_PRICES)
    names = {i["name"] for i in indices}
    assert {"IHSG", "Hang Seng", "KOSPI Composite",
            "KOSDAQ Composite"} <= names
    symbols = {i["symbol"] for i in indices}
    assert symbols == set(_PRICES)
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
    assert len(indices) == len(_PRICES)
    for i in indices:
        assert i["available"] is False
        assert i["price"] is None
        assert i["change"] is None
        assert i["change_percent"] is None


# --------------------------------------------------------------------------- #
# Absurd-candle sanity guard (Yahoo rate-limited / partial candle)            #
# --------------------------------------------------------------------------- #
def test_absurd_daily_move_is_rejected_not_fabricated():
    """A Yahoo partial/rate-limited candle that parses into a >25% one-day
    move (e.g. IHSG '754.83 / -87%') must NOT be served as a real quote."""

    def absurd(ticker, period="5d", interval="1d"):
        return _close_only([6007.66, 754.83])  # ~ -87% in one session

    svc = MarketIndicesService(fetcher=absurd, now_provider=_closed_now)
    svc._intraday_last = lambda s: None  # type: ignore[assignment]
    q = {q.market: q for q in svc.get_indices()}[Market.IDX]
    assert q.available is False
    assert q.price is None
    assert q.change_percent is None


def test_last_good_quote_survives_a_bad_fetch():
    """Once a good quote is cached, a subsequent absurd/failed fetch keeps
    serving the last-good value instead of regressing to a blank index."""

    seq = [
        lambda t, p="5d", i="1d": _close_only([5886.0, 6007.66]),  # good
        lambda t, p="5d", i="1d": _close_only([6007.66, 754.83]),   # absurd
    ]

    def seq_fetch(ticker, period="5d", interval="1d"):
        return seq.pop(0)(ticker, period, interval)

    # ttl=0 forces a re-fetch on the second read.
    svc = MarketIndicesService(
        fetcher=seq_fetch, now_provider=_closed_now, ttl_seconds=0
    )
    svc._intraday_last = lambda s: None  # type: ignore[assignment]
    spec = INDEX_BY_MARKET[Market.IDX]
    first = svc._get_one(spec)
    second = svc._get_one(spec)  # bad fetch -> must keep last-good
    assert first.available is True and first.price == 6007.66
    assert second.available is True and second.price == 6007.66


def test_intraday_falls_back_to_5m_when_1m_is_empty():
    """Yahoo returns an EMPTY 1d/1m frame for some index symbols (^JKSE), which
    used to freeze the index on a stale daily close. The service must fall back
    to a coarser intraday window (5d/5m) that DOES carry today's tick and serve
    that fresher level."""

    daily_idx = pd.to_datetime(["2026-06-11", "2026-06-12"])
    daily = pd.DataFrame({"Close": [5886.0, 6007.66]}, index=daily_idx)
    # A fresher intraday tick on a LATER trading day.
    intra_idx = pd.to_datetime(["2026-06-15 08:00", "2026-06-15 09:00"])
    intra_5m = pd.DataFrame({"Close": [6200.0, 6254.97]}, index=intra_idx)

    def fetch(ticker, period="5d", interval="1d"):
        if interval == "1d":
            return daily
        if (period, interval) == ("1d", "1m"):
            return pd.DataFrame({"Close": []})  # empty 1m, like ^JKSE
        if (period, interval) == ("5d", "5m"):
            return intra_5m
        raise ValueError(f"unexpected {period}/{interval}")

    svc = MarketIndicesService(fetcher=fetch, now_provider=_closed_now)
    q = {q.market: q for q in svc.get_indices()}[Market.IDX]
    assert q.available is True
    # Served the fresher 5m tick, change recomputed vs the last daily close.
    assert q.price == 6254.97
    assert q.change == pytest.approx(247.31, abs=0.01)


def test_corrupt_scale_daily_close_is_rejected():
    """Yahoo sometimes returns a daily Close that is an order of magnitude off
    (e.g. 67 when IHSG trades ~6000). The change% guard misses it when the
    move looks small, so a level/median sanity check must reject it instead of
    serving a wrong index level."""

    def corrupt(ticker, period="5d", interval="1d"):
        # Latest daily row is mis-scaled (67) amid normal ~6000 closes.
        return _close_only([5902.0, 5886.0, 6007.66, 67.1])

    svc = MarketIndicesService(fetcher=corrupt, now_provider=_closed_now)
    svc._intraday_last = lambda s: None  # type: ignore[assignment]
    q = {q.market: q for q in svc.get_indices()}[Market.IDX]
    assert q.available is False
    assert q.price is None


def test_corrupt_intraday_tick_is_ignored_keeping_daily_level():
    """A mis-scaled intraday tick (67) on a newer trading day must NOT replace
    the trusted daily close (~6000); the daily level is served instead."""

    daily = _close_only([5886.0, 6007.66])  # latest daily 12 Jun-ish
    daily.index = pd.to_datetime(["2026-06-11", "2026-06-12"])

    def fetch(ticker, period="5d", interval="1d"):
        return daily

    svc = MarketIndicesService(fetcher=fetch, now_provider=_closed_now)
    # Intraday returns a LATER date but a corrupt ~67 level.
    svc._intraday_last = lambda s: (  # type: ignore[assignment]
        __import__("datetime").date(2026, 6, 15),
        67.1,
    )
    q = {q.market: q for q in svc.get_indices()}[Market.IDX]
    assert q.available is True
    assert q.price == 6007.66  # kept the trusted daily level
