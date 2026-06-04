"""Screener ranking fixes: liquidity tiebreaker + liquidity filter.

See docs/screener-ranking-audit.md. These verify Fix A (sort tiebreaker) and
Fix B (min_value_traded floor) without touching score/signal/category logic.
"""

import numpy as np
import pandas as pd

from app.engine import (
    AnalysisEngine,
    DEFAULT_MIN_VALUE_TRADED_IDR,
    default_min_value_traded,
)
from app.models import Market, ScreenerCategory, ScreenerMatch, ScreenerResult


def _match(symbol, score, value_traded, change=0.0, cats=None):
    return ScreenerMatch(
        symbol=symbol,
        name=symbol,
        score=score,
        signal="BUY",
        price=100.0,
        change_percent=change,
        categories=cats or [ScreenerCategory.bullish],
        value_traded=value_traded,
    )


def _result(matches):
    return ScreenerResult(
        market=Market.IDX, matches=matches, generated_at="2026-06-05T00:00:00Z"
    )


# --- Fix A: liquidity tiebreaker --------------------------------------------

def test_higher_value_traded_wins_when_score_identical():
    # Three names all at score 86; should rank by value_traded desc.
    matches = [
        _match("LOWLIQ", 86.0, 50_000_000, change=10.0),   # tiny turnover
        _match("BIGLIQ", 86.0, 3_000_000_000_000),         # 3T turnover
        _match("MIDLIQ", 86.0, 5_000_000_000),             # 5B turnover
    ]
    res = AnalysisEngine._finalize(_result(matches), limit=50, min_score=0,
                                   categories=None, min_value_traded=0)
    order = [m.symbol for m in res.matches]
    assert order == ["BIGLIQ", "MIDLIQ", "LOWLIQ"]


def test_score_still_dominates_over_liquidity():
    # A higher score outranks higher liquidity (score is primary key).
    matches = [
        _match("HISCORE", 90.0, 1_000),                    # tiny turnover
        _match("LOSCORE", 86.0, 9_000_000_000_000),        # huge turnover
    ]
    res = AnalysisEngine._finalize(_result(matches), limit=50, min_score=0,
                                   categories=None, min_value_traded=0)
    assert [m.symbol for m in res.matches] == ["HISCORE", "LOSCORE"]


def test_change_percent_breaks_remaining_ties():
    # Same score AND same value_traded -> change_percent desc decides.
    matches = [
        _match("A", 86.0, 5_000_000_000, change=-3.0),
        _match("B", 86.0, 5_000_000_000, change=4.0),
    ]
    res = AnalysisEngine._finalize(_result(matches), limit=50, min_score=0,
                                   categories=None, min_value_traded=0)
    assert [m.symbol for m in res.matches] == ["B", "A"]


# --- Fix B: liquidity filter ------------------------------------------------

def test_low_liquidity_is_filtered_out():
    matches = [
        _match("BIG", 86.0, 3_000_000_000),     # >= 2B floor
        _match("SHELL", 86.0, 0),               # untraded
        _match("MICRO", 86.0, 63_000_000),      # 63M, below 2B
    ]
    res = AnalysisEngine._finalize(
        _result(matches), limit=50, min_score=0, categories=None,
        min_value_traded=2_000_000_000,
    )
    symbols = {m.symbol for m in res.matches}
    assert symbols == {"BIG"}
    assert res.total_count == 1  # SHELL + MICRO excluded before pagination


def test_zero_floor_keeps_everything():
    matches = [
        _match("BIG", 86.0, 3_000_000_000),
        _match("SHELL", 86.0, 0),
    ]
    res = AnalysisEngine._finalize(_result(matches), limit=50, min_score=0,
                                   categories=None, min_value_traded=0)
    assert len(res.matches) == 2


def test_per_market_default_floor_scaling():
    assert default_min_value_traded(Market.IDX) == DEFAULT_MIN_VALUE_TRADED_IDR
    # HKEX/KOSPI/KOSDAQ scaled below the raw IDR figure.
    assert default_min_value_traded(Market.HKEX) < DEFAULT_MIN_VALUE_TRADED_IDR
    assert default_min_value_traded(Market.KOSPI) < DEFAULT_MIN_VALUE_TRADED_IDR
    assert default_min_value_traded(Market.KOSDAQ) < DEFAULT_MIN_VALUE_TRADED_IDR


# --- engine.screen integration ----------------------------------------------

def _universe_engine(tmp_path):
    (tmp_path / "idx.csv").write_text(
        "symbol,name\nAAA,Co A\nBBB,Co B\nCCC,Co C\n"
    )
    from app.universe import UniverseRepository

    # Per-symbol synthetic data with differing turnover via volume.
    def fetch(ticker, period, interval):
        base = {"AAA.JK": 1_000.0, "BBB.JK": 9_000.0, "CCC.JK": 50.0}
        vol = base.get(ticker, 1_000.0)
        n = 300
        close = 100 + np.arange(n) * 1.0  # uptrend -> same score for all
        return pd.DataFrame({
            "Open": close, "High": close + 1, "Low": close - 1,
            "Close": close, "Volume": np.full(n, vol),
        })

    return AnalysisEngine(
        fetcher=fetch, universe=UniverseRepository(universe_dir=tmp_path)
    )


def test_screen_orders_by_liquidity_when_scores_tie(tmp_path):
    eng = _universe_engine(tmp_path)
    res = eng.screen(Market.IDX, min_value_traded=0)
    # All three share the uptrend score; order must follow value_traded desc.
    assert [m.symbol for m in res.matches] == ["BBB", "AAA", "CCC"]
    assert res.matches[0].value_traded > res.matches[-1].value_traded


def test_screen_filters_below_threshold(tmp_path):
    eng = _universe_engine(tmp_path)
    # close ~ 399 at the last bar; CCC volume 50 -> ~20k turnover (filtered);
    # AAA vol 1000 -> ~399k; BBB vol 9000 -> ~3.6M. Floor at 1M keeps only BBB.
    res = eng.screen(Market.IDX, min_value_traded=1_000_000)
    assert [m.symbol for m in res.matches] == ["BBB"]


# --- regression: score/signal/contract unchanged ----------------------------

def test_score_calculation_unchanged():
    # Uptrend fixture -> the existing quantized 80 (no change to _signal_and_score).
    eng = AnalysisEngine()
    n = 300
    close = 100 + np.arange(n) * 1.0
    df = pd.DataFrame({
        "Open": close, "High": close + 1, "Low": close - 1, "Close": close,
        "Volume": np.full(n, 1000.0),
    })
    from app import indicators
    ind = indicators.compute_all(df)
    cats = eng.categorize(ind, Market.IDX)
    signal, score = eng._signal_and_score(ind, cats)
    assert signal == "BUY"
    assert score == 80.0  # unchanged from before the ranking fix


def test_screenermatch_contract_has_value_traded_default():
    # value_traded is additive with a default -> old payloads still validate.
    m = ScreenerMatch(
        symbol="X", score=86.0, price=100.0, change_percent=1.0,
    )
    assert m.value_traded == 0.0  # default, backward-compatible
    # And the previously-required fields are intact.
    assert m.symbol == "X" and m.signal == "HOLD"
