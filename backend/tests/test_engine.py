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


def test_screen_limit_and_sort_order():
    eng = AnalysisEngine(fetcher=lambda t, p, i: uptrend())
    res = eng.screen(Market.HKEX, limit=3)  # mock universe via fallback
    assert len(res.matches) <= 3
    scores = [m.score for m in res.matches]
    assert scores == sorted(scores, reverse=True)
    # Tie-break by change_percent desc within equal scores.
    for a, b in zip(res.matches, res.matches[1:]):
        if a.score == b.score:
            assert a.change_percent >= b.change_percent


def test_screen_limit_is_bounded_to_max():
    eng = AnalysisEngine(fetcher=lambda t, p, i: uptrend())
    res = eng.screen(Market.IDX, limit=99999)
    assert len(res.matches) <= 200  # MAX_LIMIT
    assert res.limit == 200  # echoed back, clamped


def test_screen_metadata_counts():
    eng = AnalysisEngine(fetcher=lambda t, p, i: uptrend())
    # Mock universe has 10 rows; limit to 3.
    res = eng.screen(Market.HKEX, limit=3)
    assert res.returned_count == len(res.matches) == 3
    assert res.total_count >= res.returned_count
    assert res.total_count == 10  # all 10 mock rows pass (no filter)
    assert res.limit == 3
    assert res.min_score == 0.0
    assert res.categories == []


def test_screen_metadata_reflects_filters():
    eng = AnalysisEngine(fetcher=lambda t, p, i: uptrend())
    res = eng.screen(
        Market.IDX, limit=50, min_score=80,
        categories=[ScreenerCategory.bullish],
    )
    assert res.min_score == 80
    assert res.categories == [ScreenerCategory.bullish]
    assert res.total_count == res.returned_count  # within limit


def test_screen_min_score_filters():
    eng = AnalysisEngine(fetcher=lambda t, p, i: uptrend())
    res = eng.screen(Market.IDX, min_score=80)
    assert all(m.score >= 80 for m in res.matches)


def test_screen_category_filter():
    eng = AnalysisEngine(fetcher=lambda t, p, i: uptrend())
    res = eng.screen(Market.IDX, categories=[ScreenerCategory.bearish])
    # Synthetic uptrend produces bullish matches, so a bearish filter is empty.
    assert res.matches == []

    res2 = eng.screen(Market.IDX, categories=[ScreenerCategory.bullish])
    assert len(res2.matches) > 0
    assert all(ScreenerCategory.bullish in m.categories for m in res2.matches)


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


def test_screen_failed_symbol_uses_mock_not_skipped():
    # Fetcher always fails -> every symbol must still produce a match.
    def boom(t, p, i):
        raise ConnectionError("offline")

    eng = AnalysisEngine(fetcher=boom)
    res = eng.screen(Market.IDX, symbols=["BBCA", "TLKM", "GOTO"], limit=50)
    assert {m.symbol for m in res.matches} == {"BBCA", "TLKM", "GOTO"}
    for m in res.matches:
        assert 0 <= m.score <= 100
        assert m.signal in {"BUY", "HOLD", "SELL"}
        assert m.categories  # non-empty deterministic categories


def test_screen_mixed_success_and_failure_all_populated():
    # GOOD* succeeds (real indicators); BAD* fails -> mock fallback per symbol.
    def fetch(t, p, i):
        if t.startswith("GOOD"):
            return uptrend()
        raise ValueError("no data")

    eng = AnalysisEngine(fetcher=fetch)
    res = eng.screen(
        Market.IDX, symbols=["GOOD1", "BAD1", "GOOD2", "BAD2"], limit=50
    )
    assert {m.symbol for m in res.matches} == {"GOOD1", "BAD1", "GOOD2", "BAD2"}
    assert res.total_count == 4  # nothing dropped


def test_screen_failed_symbol_is_deterministic():
    def boom(t, p, i):
        raise ConnectionError("offline")

    eng = AnalysisEngine(fetcher=boom)
    a = eng.screen(Market.HKEX, symbols=["0700"], limit=50).matches[0]
    b = eng.screen(Market.HKEX, symbols=["0700"], limit=50).matches[0]
    assert (a.symbol, a.score, a.signal, a.categories) == (
        b.symbol, b.score, b.signal, b.categories,
    )


def test_screen_failed_symbol_keeps_universe_name(tmp_path):
    (tmp_path / "idx.csv").write_text(
        "symbol,name\nBBCA,Bank Central Asia\n"
    )

    def boom(t, p, i):
        raise ConnectionError("offline")

    eng = AnalysisEngine(
        fetcher=boom, universe=UniverseRepository(universe_dir=tmp_path)
    )
    res = eng.screen(Market.IDX)
    assert res.matches[0].symbol == "BBCA"
    assert res.matches[0].name == "Bank Central Asia"  # name preserved
