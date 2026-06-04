"""Engine tests using injected synthetic fetchers (no network)."""

import numpy as np
import pandas as pd
import pytest

from app import indicators
from app.engine import AnalysisEngine, yf_symbol
from app.models import Market, ScreenerCategory
from app.universe import UniverseRepository


def make_ohlcv(close, volume=None, n=None):
    close = np.asarray(close, dtype="float64")
    n = n or len(close)
    if volume is None:
        volume = np.full(n, 1000.0)
    return pd.DataFrame(
        {
            "Open": close,
            "High": close + np.abs(close) * 0.01 + 0.5,
            "Low": close - np.abs(close) * 0.01 - 0.5,
            "Close": close,
            "Volume": np.asarray(volume, dtype="float64"),
        }
    )


def uptrend(n=300, start=100.0, step=1.0):
    return make_ohlcv(start + np.arange(n) * step, n=n)


def downtrend(n=300, start=400.0, step=1.0):
    return make_ohlcv(start - np.arange(n) * step, n=n)


# ---- symbol mapping ----------------------------------------------------------

@pytest.mark.parametrize(
    "market,suffix",
    [
        (Market.IDX, ".JK"),
        (Market.HKEX, ".HK"),
        (Market.KOSPI, ".KS"),
        (Market.KOSDAQ, ".KQ"),
    ],
)
def test_yf_symbol_suffix(market, suffix):
    assert yf_symbol("bbca", market) == f"BBCA{suffix}"
    # Idempotent: already-suffixed stays as-is.
    assert yf_symbol(f"BBCA{suffix}", market) == f"BBCA{suffix}"


# ---- analyze -----------------------------------------------------------------

def test_analyze_uptrend_is_bullish_buy():
    eng = AnalysisEngine(fetcher=lambda t, p, i: uptrend())
    res = eng.analyze("BBCA", Market.IDX)
    assert res.signal == "BUY"
    assert res.score >= 66
    assert 0 <= res.score <= 100
    assert any(h.startswith("RSI") for h in res.highlights)


def test_analyze_downtrend_is_bearish_sell():
    eng = AnalysisEngine(fetcher=lambda t, p, i: downtrend())
    res = eng.analyze("XYZ", Market.HKEX)
    assert res.signal == "SELL"
    assert res.score <= 40


def test_analyze_falls_back_to_mock_on_fetch_error():
    def boom(ticker, period, interval):
        raise ConnectionError("offline")

    eng = AnalysisEngine(fetcher=boom)
    res = eng.analyze("TLKM", Market.IDX)
    # Mock fallback still produces a valid, well-formed result.
    assert res.symbol == "TLKM"
    assert res.signal in {"BUY", "HOLD", "SELL"}
    assert 0 <= res.score <= 100


def test_analyze_falls_back_on_empty_data():
    eng = AnalysisEngine(fetcher=lambda t, p, i: make_ohlcv([100.0], n=1))
    res = eng.analyze("AAA", Market.KOSPI)
    # 1 row => indicators are NaN => fallback to mock.
    assert res.symbol == "AAA"
    assert res.signal in {"BUY", "HOLD", "SELL"}


# ---- categories --------------------------------------------------------------

def test_categorize_bullish_on_uptrend():
    eng = AnalysisEngine(fetcher=lambda t, p, i: uptrend())
    res = eng.analyze("UP", Market.IDX)
    assert "bullish" in res.summary


def test_categorize_ara_hunter_on_surge():
    eng = AnalysisEngine()
    n = 300
    close = 100 + np.arange(n) * 0.5
    # Sharp final spike to push RSI very high, with a volume surge.
    close = close.astype("float64")
    close[-5:] = close[-6] * np.array([1.08, 1.16, 1.25, 1.34, 1.45])
    volume = np.full(n, 1000.0)
    volume[-1] = 5000.0  # 5x surge
    ind = indicators.compute_all(make_ohlcv(close, volume=volume, n=n))
    cats = eng.categorize(ind)
    assert ScreenerCategory.ara_hunter in cats


# ---- predict_weekly ----------------------------------------------------------

def test_predict_uptrend_is_up():
    eng = AnalysisEngine(fetcher=lambda t, p, i: uptrend())
    res = eng.predict_weekly("BBCA", Market.IDX)
    assert res.direction == "UP"
    assert res.expected_change_percent >= 0
    assert 0 <= res.confidence <= 1


def test_predict_falls_back_on_error():
    def boom(ticker, period, interval):
        raise ValueError("no data")

    eng = AnalysisEngine(fetcher=boom)
    res = eng.predict_weekly("ZZZ", Market.KOSDAQ)
    assert res.symbol == "ZZZ"
    assert res.direction in {"UP", "DOWN", "FLAT"}


# ---- screen ------------------------------------------------------------------

def test_screen_with_universe_ranks_by_score():
    def fetch(ticker, period, interval):
        return uptrend() if ticker.startswith("GOOD") else downtrend()

    eng = AnalysisEngine(fetcher=fetch)
    res = eng.screen(Market.IDX, symbols=["GOOD1", "BAD1", "GOOD2"])
    assert len(res.matches) == 3
    scores = [m.score for m in res.matches]
    assert scores == sorted(scores, reverse=True)  # ranked desc


def test_screen_no_universe_falls_back_to_mock():
    eng = AnalysisEngine(fetcher=lambda t, p, i: uptrend())
    res = eng.screen(Market.HKEX)  # no symbols
    assert res.market == Market.HKEX
    assert len(res.matches) > 0  # mock provides rows


def test_screen_uses_market_universe(tmp_path):
    # A controlled 2-symbol universe loaded from disk.
    (tmp_path / "idx.csv").write_text(
        "symbol,name\nBBCA,Bank Central Asia\nTLKM,Telkom Indonesia\n"
    )
    eng = AnalysisEngine(
        fetcher=lambda t, p, i: uptrend(),
        universe=UniverseRepository(universe_dir=tmp_path),
    )
    res = eng.screen(Market.IDX)  # no explicit symbols -> uses universe
    assert {m.symbol for m in res.matches} == {"BBCA", "TLKM"}
    # Name enrichment comes from the universe file.
    bbca = next(m for m in res.matches if m.symbol == "BBCA")
    assert bbca.name == "Bank Central Asia"
    assert bbca.signal == "BUY"  # uptrend synthetic data
