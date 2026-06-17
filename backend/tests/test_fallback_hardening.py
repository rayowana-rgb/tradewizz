"""Phase D: screener fallback + Vietnam index hardening.

Covers:
  * mock fallback DataFrame / match construction (no ValueError, valid OHLCV,
    marked mock, never BUY / elite);
  * screener fallback isolation (one bad ticker doesn't fail the whole screen,
    and never becomes a BUY / elite opportunity);
  * Vietnam index graceful unavailability (no crash, available=false), with
    other indices unaffected;
  * market condition for an unavailable index (UNKNOWN, null score, no crash);
  * no per-symbol ERROR log spam on the normal fallback path.
"""

from __future__ import annotations

import logging

import numpy as np
import pandas as pd
import pytest

from app import indicators, mock_data
from app.engine import AnalysisEngine
from app.market.condition import classify_condition
from app.market.service import (
    INDEX_BY_MARKET,
    INDEX_SPECS,
    MarketConditionService,
    MarketIndicesService,
)
from app.models import Market
from app.universe import UniverseRepository


# --------------------------------------------------------------------------- #
# helpers                                                                      #
# --------------------------------------------------------------------------- #
def _ohlcv(close, volume=None, n=None):
    close = np.asarray(close, dtype="float64")
    n = n or len(close)
    if volume is None:
        volume = np.full(n, 1000.0)
    return pd.DataFrame(
        {
            "Open": close,
            "High": close + 1.0,
            "Low": close - 1.0,
            "Close": close,
            "Volume": np.asarray(volume, dtype="float64"),
        }
    )


def _closed_now(market):
    from datetime import datetime
    from zoneinfo import ZoneInfo

    # A Sunday -> every market closed.
    return datetime(2026, 6, 7, 12, 0, tzinfo=ZoneInfo("UTC"))


# --------------------------------------------------------------------------- #
# D1: mock fallback construction                                              #
# --------------------------------------------------------------------------- #
def test_scalar_dataframe_repro_is_the_known_error():
    """Sanity: a scalar-valued dict is exactly the error we guard against."""
    with pytest.raises(ValueError, match="you must pass an index"):
        pd.DataFrame({"Close": 10.5, "Volume": 1000})


def test_compute_all_on_single_row_does_not_raise():
    """A 1-row OHLCV frame must yield a valid dict, never a scalar ValueError."""
    df = _ohlcv([10.5], volume=[1000], n=1)
    out = indicators.compute_all(df)  # must not raise
    assert out["close"] == 10.5
    assert out["value_traded"] == pytest.approx(10.5 * 1000)


def test_mock_screener_match_is_valid_and_marked_mock():
    m = mock_data.mock_screener_match("ABMM", Market.IDX, "Test Co")
    # Valid, well-formed row with price + value_traded populated.
    assert m.symbol == "ABMM"
    assert m.price > 0
    assert m.value_traded > 0
    # Marked as fallback so consumers can exclude it.
    assert m.data_source == "mock"
    assert m.illiquid is True


def test_mock_fallback_never_buy_or_elite():
    """No-data fallback rows must never be BUY nor reach the elite score band."""
    for sym in ("ABMM", "ADHI", "AALI", "BBCA", "TLKM", "PUMP", "ZZZZ"):
        m = mock_data.mock_screener_match(sym, Market.IDX, "")
        assert m.signal == "HOLD"
        assert m.score < 66  # below any BUY / elite threshold


# --------------------------------------------------------------------------- #
# D2: screener fallback isolation                                            #
# --------------------------------------------------------------------------- #
def _uptrend(n=300, start=100.0):
    close = start + np.arange(n, dtype="float64")
    vol = np.full(n, 5_000_000.0)
    return _ohlcv(close, volume=vol, n=n)


def test_one_bad_ticker_does_not_fail_whole_screen(tmp_path):
    def fetch(ticker, period, interval):
        if ticker.startswith("BAD"):
            raise ConnectionError("offline")
        return _uptrend()

    eng = AnalysisEngine(fetcher=fetch)
    res = eng.screen(Market.IDX, symbols=["GOOD1", "BAD1", "GOOD2"])
    # The bad ticker doesn't fail the whole screen: the two live names still
    # come back. The mock-fallback row is held out (it would carry fabricated
    # seeded prices), so it must NOT appear among the visible matches.
    by_sym = {m.symbol: m for m in res.matches}
    assert {"GOOD1", "GOOD2"}.issubset(by_sym.keys())
    assert "BAD1" not in by_sym
    assert by_sym["GOOD1"].data_source == "live"
    assert all(m.data_source == "live" for m in res.matches)


def test_fallback_ticker_never_becomes_buy_or_elite():
    def fetch(ticker, period, interval):
        if ticker.startswith("BAD"):
            raise ValueError("no data")
        return _uptrend()

    eng = AnalysisEngine(fetcher=fetch)
    # The mock row is held out of the screen result; inspect it directly to
    # confirm it can never read as BUY/elite.
    bad = eng._screen_one("BAD1", Market.IDX, {})
    assert bad.signal != "BUY"
    assert bad.score < 66
    res = eng.screen(Market.IDX, symbols=["GOOD1", "BAD1"])
    assert "BAD1" not in {m.symbol for m in res.matches}
    # And it is excluded from ranked opportunities (radar / best idea).
    from app.radar.service import RadarService

    radar = RadarService(screen_provider=eng.screen)
    opps = radar._opportunities_for(Market.IDX, limit=50)
    assert all(o.symbol != "BAD1" for o in opps)


# --------------------------------------------------------------------------- #
# D3: Vietnam index graceful unavailability                                  #
# --------------------------------------------------------------------------- #
def test_vietnam_index_is_marked_non_fetchable():
    spec = INDEX_BY_MARKET[Market.VIETNAM]
    assert spec.fetchable is False
    assert spec.unavailable_reason


def test_vietnam_index_unavailable_without_fetch():
    calls = {"n": 0}

    def fetch(ticker, period="5d", interval="1d"):
        calls["n"] += 1
        # Simulate Yahoo 404 if anything dares to fetch VN-Index.
        if "VNINDEX" in ticker:
            raise ValueError("404 not found")
        return _ohlcv([100.0, 101.0])

    svc = MarketIndicesService(fetcher=fetch, now_provider=_closed_now)
    quotes = {q.market: q for q in svc.get_indices()}
    vn = quotes[Market.VIETNAM]
    assert vn.available is False
    assert vn.price is None
    # Other indices still resolve to available quotes.
    assert quotes[Market.IDX].available is True
    # The VN symbol was never fetched (no 404 spam).
    # Only fetchable indices hit the fetcher, and each does a daily + a
    # best-effort intraday fetch (to surface today's level when daily lags).
    assert calls["n"] == sum(1 for s in INDEX_SPECS if s.fetchable) * 3


def test_one_failed_index_does_not_affect_others():
    def fetch(ticker, period="5d", interval="1d"):
        if "JKSE" in ticker:
            raise ConnectionError("idx down")
        return _ohlcv([100.0, 102.0])

    svc = MarketIndicesService(fetcher=fetch, now_provider=_closed_now)
    quotes = {q.market: q for q in svc.get_indices()}
    assert quotes[Market.IDX].available is False  # isolated failure
    assert quotes[Market.US].available is True    # unaffected


# --------------------------------------------------------------------------- #
# D4: market condition for an unavailable index                              #
# --------------------------------------------------------------------------- #
def test_condition_unavailable_index_returns_unknown_null_score():
    svc = MarketConditionService(fetcher=lambda *a, **k: _ohlcv([100.0] * 60))
    cond = svc.get(Market.VIETNAM)
    assert cond.condition == "UNKNOWN"
    assert cond.available is False
    d = cond.to_dict()
    assert d["condition"] == "UNKNOWN"
    assert d["condition_score"] is None
    assert d["available"] is False


def test_condition_failed_fetch_does_not_crash():
    def boom(*a, **k):
        raise ValueError("delisted")

    svc = MarketConditionService(fetcher=boom)
    cond = svc.get(Market.IDX)  # fetchable but fetch fails
    assert cond.condition == "UNKNOWN"


def test_classify_condition_insufficient_data_is_unknown():
    assert classify_condition([]).condition == "UNKNOWN"
    assert classify_condition([100.0] * 5).condition == "UNKNOWN"


# --------------------------------------------------------------------------- #
# D5: log cleanup                                                            #
# --------------------------------------------------------------------------- #
def test_no_per_symbol_error_spam_on_fallback(caplog):
    def fetch(ticker, period, interval):
        if ticker.startswith("BAD"):
            raise ConnectionError("offline")
        return _uptrend()

    eng = AnalysisEngine(fetcher=fetch)
    with caplog.at_level(logging.WARNING, logger="app.engine"):
        eng.screen(Market.IDX, symbols=["GOOD1", "BAD1", "BAD2", "BAD3"])

    # No per-symbol "mock-fallback for X" lines at WARNING/ERROR.
    per_symbol = [
        r for r in caplog.records
        if "mock-fallback for" in r.getMessage()
        and r.levelno >= logging.WARNING
    ]
    assert per_symbol == []

    # Exactly one aggregated market-level summary at WARNING.
    summaries = [
        r for r in caplog.records
        if "screen fallback used for" in r.getMessage()
    ]
    assert len(summaries) == 1
    assert "3/4" in summaries[0].getMessage()
