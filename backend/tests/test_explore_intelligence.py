"""Phase 9A: Explore intelligence (bot9 category bonus + conviction overlay).

Proves the 7 Rule-8 requirements:
  1. Existing scoring engine unchanged (Base Score == prior score path).
  2. Liquidity cap still works (illiquid -> capped, not BUY).
  3. Bot9 categories add a (capped) bonus.
  4. Conviction Score works (0..20 from CMF/OBV/ADX/volume/MACD/RSI).
  5. Final ranking uses the Explore Score, not the Base Score.
  6. Illiquid stocks cannot reach the top ranks.
  7. Mock / no-data stocks cannot receive bonuses.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from app import explore, scoring
from app.engine import AnalysisEngine
from app.models import Market, ScreenerCategory as C, ScreenerMatch


# --------------------------------------------------------------------------- #
# helpers                                                                      #
# --------------------------------------------------------------------------- #
def _ohlcv(close, volume=None, n=None):
    close = np.asarray(close, dtype="float64")
    n = n or len(close)
    if volume is None:
        volume = np.full(n, 1_000_000.0)
    return pd.DataFrame(
        {
            "Open": close,
            "High": close + np.abs(close) * 0.01 + 0.5,
            "Low": close - np.abs(close) * 0.01 - 0.5,
            "Close": close,
            "Volume": np.asarray(volume, dtype="float64"),
        }
    )


def _liquid_uptrend(n=300, start=1000.0, step=3.0):
    """A liquid, healthy uptrend (large turnover so it isn't capped)."""
    close = start + np.arange(n, dtype="float64") * step
    vol = np.full(n, 50_000_000.0)
    return _ohlcv(close, volume=vol, n=n)


def _illiquid_uptrend(n=300, start=1000.0, step=3.0):
    """Same shape but tiny turnover -> illiquid (liquidity cap should bite)."""
    close = start + np.arange(n, dtype="float64") * step
    vol = np.full(n, 5.0)  # value traded ~ a few thousand IDR
    return _ohlcv(close, volume=vol, n=n)


# --------------------------------------------------------------------------- #
# Rule 8 #1 — existing scoring engine unchanged                              #
# --------------------------------------------------------------------------- #
def test_base_score_equals_prior_engine_output():
    """The overlay must not touch the Base Score: base_score == score and the
    score equals what _signal_and_score() produced (the legacy path)."""
    from app import indicators

    eng = AnalysisEngine(fetcher=lambda t, p, i: _liquid_uptrend())
    res = eng.screen(Market.IDX, symbols=["GOOD1"])
    m = res.matches[0]

    # Recompute the Base Score independently via the untouched engine path.
    df = _liquid_uptrend()
    ind = indicators.compute_all(df)
    cats = eng.categorize(ind, Market.IDX)
    ctx = eng._market_context(df, Market.IDX)
    _signal, base = eng._signal_and_score(ind, cats, ctx=ctx, market=Market.IDX)

    assert m.base_score == base
    assert m.score == base  # legacy field unchanged


def test_overlay_module_is_pure_and_additive():
    # category_bonus + conviction are deterministic and never mutate inputs.
    cats = [C.bullish]
    ind = {"cmf": 0.1}
    b1 = explore.category_bonus(cats)
    b2 = explore.category_bonus(cats)
    assert b1 == b2 == 5
    assert cats == [C.bullish]  # untouched


# --------------------------------------------------------------------------- #
# Rule 8 #2 — liquidity cap still works                                       #
# --------------------------------------------------------------------------- #
def test_liquidity_cap_still_applies():
    eng = AnalysisEngine(fetcher=lambda t, p, i: _illiquid_uptrend())
    res = eng.screen(Market.IDX, symbols=["TINY1"])
    m = res.matches[0]
    assert m.illiquid is True
    assert m.signal != "BUY"          # illiquid can't be BUY
    assert m.category_bonus == 0      # no overlay on illiquid
    assert m.conviction_score == 0
    assert m.final_score == m.base_score  # final == base for illiquid


# --------------------------------------------------------------------------- #
# Rule 8 #3 — bot9 categories add bonus (capped)                              #
# --------------------------------------------------------------------------- #
def test_category_bonus_weights_and_cap():
    assert explore.category_bonus([C.bullish]) == 5
    assert explore.category_bonus([C.pullback]) == 5
    assert explore.category_bonus([C.accumulation]) == 8
    assert explore.category_bonus([C.frequently_traded]) == 5
    assert explore.category_bonus([C.turnaround_multibagger]) == 12
    assert explore.category_bonus([C.accumulation_silent]) == 15
    assert explore.category_bonus([C.ara_hunter]) == 10
    # Sum well over 25 -> capped at 25.
    big = [
        C.accumulation_silent, C.turnaround_multibagger,
        C.ara_hunter, C.accumulation,
    ]
    assert explore.category_bonus(big) == 25
    # Empty / no-bonus categories -> 0.
    assert explore.category_bonus([]) == 0


def test_short_candidate_never_adds_score():
    assert explore.category_bonus([C.short_candidate]) == 0
    # short_candidate present alongside a bonus category contributes nothing.
    assert explore.category_bonus([C.short_candidate, C.bullish]) == 5


def test_category_bonus_lifts_final_above_base():
    base = 60.0
    cats = [C.accumulation]  # +8
    ind = {}  # no conviction
    overlay = explore.compute_overlay(base, cats, ind)
    assert overlay["category_bonus"] == 8
    # Phase 9A+: the overlay consumes headroom proportionally. With OVERLAY_MAX
    # now 51 (CATEGORY_BONUS_CAP 25 + CONVICTION_MAX 26), a +8 bonus on a Base
    # of 60 lifts the final to 60 + (100-60)*(8/51) = 66.3, still above the Base
    # (the "bonus lifts final above base" contract holds).
    assert overlay["final_score"] == 66.3


def test_overlay_respects_liquidity_score_ceiling():
    """Regression: the additive overlay must not breach the liquidity cap.

    A thin name whose Base Score was capped at its value-traded tier (e.g. IDX
    <Rp5B -> 75) must keep a Final Score at/under that ceiling even when the
    category bonus + conviction would otherwise lift it higher.
    """
    base = 75.0  # already capped at the <Rp5B tier
    cats = [C.bullish, C.accumulation]  # +13 worth of bonus
    ind = {  # full conviction would add up to +20
        "cmf": 0.3,
        "obv": 1.0,
        "obv_prev": 0.0,
        "adx": 40.0,
    }
    # Without a ceiling the overlay lifts the final well above 75.
    uncapped = explore.compute_overlay(base, cats, ind)
    assert uncapped["final_score"] > 75.0
    # With the liquidity ceiling supplied, the final is clamped to it; the
    # bonus/conviction read-outs are still surfaced for transparency.
    capped = explore.compute_overlay(base, cats, ind, score_ceiling=75.0)
    assert capped["final_score"] == 75.0
    assert capped["category_bonus"] > 0
    assert capped["conviction_score"] > 0
    # A ceiling never *raises* a score that is already below it.
    low = explore.compute_overlay(50.0, [], {}, score_ceiling=75.0)
    assert low["final_score"] == 50.0


# --------------------------------------------------------------------------- #
# Rule 8 #4 — conviction score works                                          #
# --------------------------------------------------------------------------- #
def test_conviction_score_full_and_partial():
    full = {
        "cmf": 0.2, "obv": 10, "obv_prev": 5, "adx": 30,
        "volume": 3000, "vol_mean_10": 1000, "macd": 1.0,
        "macd_signal": 0.5, "rsi": 60,
    }
    assert explore.conviction_score(full) == 20  # 4+4+4+3+3+2

    none = {
        "cmf": -0.1, "obv": 1, "obv_prev": 5, "adx": 10,
        "volume": 100, "vol_mean_10": 1000, "macd": 0.1,
        "macd_signal": 0.5, "rsi": 85,
    }
    assert explore.conviction_score(none) == 0

    partial = {"cmf": 0.2, "adx": 30}  # 4 + 4
    assert explore.conviction_score(partial) == 8


def test_conviction_is_none_safe_and_bounded():
    assert explore.conviction_score({}) == 0
    assert 0 <= explore.conviction_score({"cmf": 1, "adx": 99}) <= 26


# --------------------------------------------------------------------------- #
# Rule 8 #5 — final ranking uses the Explore Score                            #
# --------------------------------------------------------------------------- #
def test_ranking_uses_final_explore_score(monkeypatch):
    """Two equal Base Scores: the one with the higher Final Score ranks first,
    even though plain Base Score would tie/invert the order."""
    from app.engine import AnalysisEngine

    eng = AnalysisEngine(fetcher=lambda t, p, i: _liquid_uptrend())

    # Build two synthetic liquid matches with equal base score but different
    # overlays, then exercise the real _finalize ranking.
    a = ScreenerMatch(
        symbol="LOWBONUS", name="A", score=70.0, signal="BUY",
        price=1000.0, change_percent=1.0, categories=[C.bullish],
        value_traded=1e11, base_score=70.0, category_bonus=5,
        conviction_score=2, final_score=77.0,
    )
    b = ScreenerMatch(
        symbol="HIGHBONUS", name="B", score=70.0, signal="BUY",
        price=1000.0, change_percent=1.0,
        categories=[C.accumulation_silent], value_traded=1e11,
        base_score=70.0, category_bonus=15, conviction_score=20,
        final_score=100.0,
    )
    from app.models import ScreenerResult

    result = ScreenerResult(market=Market.IDX, matches=[a, b], generated_at="x")
    out = AnalysisEngine._finalize(result, limit=10, min_score=0.0,
                                   categories=None)
    assert [m.symbol for m in out.matches] == ["HIGHBONUS", "LOWBONUS"]


# --------------------------------------------------------------------------- #
# Rule 8 #6 — illiquid stocks cannot reach top ranks                          #
# --------------------------------------------------------------------------- #
def test_illiquid_cannot_outrank_liquid():
    def fetch(ticker, period, interval):
        return _illiquid_uptrend() if ticker.startswith("TINY") \
            else _liquid_uptrend()

    eng = AnalysisEngine(fetcher=fetch)
    res = eng.screen(Market.IDX, symbols=["TINY1", "GOOD1", "GOOD2"])
    # The liquid names rank above the capped illiquid one.
    by = {m.symbol: m for m in res.matches}
    tiny = by["TINY1"]
    assert tiny.final_score <= min(
        by["GOOD1"].final_score, by["GOOD2"].final_score
    )
    assert res.matches[-1].symbol == "TINY1"  # illiquid sinks to the bottom


# --------------------------------------------------------------------------- #
# Rule 8 #7 — mock stocks cannot receive bonuses                              #
# --------------------------------------------------------------------------- #
def test_mock_fallback_has_no_overlay():
    def fetch(ticker, period, interval):
        if ticker.startswith("BAD"):
            raise ValueError("no data")
        return _liquid_uptrend()

    eng = AnalysisEngine(fetcher=fetch)
    # A mock-fallback row is held OUT of the filtered screen result when live
    # data exists, so inspect the raw per-symbol screen output directly.
    bad = eng._screen_one("BAD1", Market.IDX, {})
    assert bad.data_source == "mock"
    assert bad.category_bonus == 0
    assert bad.conviction_score == 0
    assert bad.final_score == bad.base_score == bad.score
    assert bad.explore_tags == []
    # And it is indeed excluded from the visible matches.
    res = eng.screen(Market.IDX, symbols=["GOOD1", "BAD1"])
    assert "BAD1" not in {m.symbol for m in res.matches}


def test_mock_screen_rows_have_no_overlay():
    from app import mock_data

    res = mock_data.mock_screen(Market.HKEX)
    for m in res.matches:
        assert m.data_source == "mock"
        assert m.category_bonus == 0
        assert m.conviction_score == 0
        assert m.final_score == m.base_score
        assert m.explore_tags == []


# --------------------------------------------------------------------------- #
# Phase 12 (Task B) — trend-structure + breakout confirmations                #
# --------------------------------------------------------------------------- #
def test_trend_structure_confirmation():
    up = {"close": 110.0, "ema20": 105.0, "ema50": 100.0, "ema200": 90.0}
    assert explore.conviction_signals(up)["trend"] is True
    # Price below EMA20 -> no trend confirmation.
    down = {"close": 99.0, "ema20": 105.0, "ema50": 100.0, "ema200": 90.0}
    assert explore.conviction_signals(down)["trend"] is False
    # EMA20 below EMA50 (short stack not up) -> no trend.
    mixed = {"close": 110.0, "ema20": 98.0, "ema50": 100.0, "ema200": 90.0}
    assert explore.conviction_signals(mixed)["trend"] is False
    # Below the 200 -> no trend even if short stack is up.
    below200 = {"close": 110.0, "ema20": 105.0, "ema50": 100.0, "ema200": 120.0}
    assert explore.conviction_signals(below200)["trend"] is False
    # EMA200 missing (young history) -> short stack alone qualifies.
    young = {"close": 110.0, "ema20": 105.0, "ema50": 100.0, "ema200": None}
    assert explore.conviction_signals(young)["trend"] is True


def test_breakout_confirmation():
    bb = {"close": 51.0, "bb_upper": 50.0}
    assert explore.conviction_signals(bb)["breakout"] is True
    res = {"close": 99.5, "major_resistance": 100.0}  # within 1%
    assert explore.conviction_signals(res)["breakout"] is True
    hi = {"close": 98.5, "high_52w": 100.0}  # within 2% of the high
    assert explore.conviction_signals(hi)["breakout"] is True
    inside = {"close": 40.0, "bb_upper": 50.0, "major_resistance": 60.0,
              "high_52w": 80.0}
    assert explore.conviction_signals(inside)["breakout"] is False


def test_conviction_max_with_all_eight():
    full = {
        "cmf": 0.2, "obv": 10, "obv_prev": 5, "adx": 30,
        "volume": 3000, "vol_mean_10": 1000, "macd": 1.0,
        "macd_signal": 0.5, "rsi": 60,
        "close": 110.0, "ema20": 105.0, "ema50": 100.0, "ema200": 90.0,
        "bb_upper": 108.0,
    }
    # 4+4+4+3+3+2+3+3 = 26 == CONVICTION_MAX.
    assert explore.conviction_score(full) == 26
    assert explore.confirmations_fired(full) == 8
    assert explore.confirmations_total() == 8


# --------------------------------------------------------------------------- #
# Phase 12 (Task A) — transparency: reasons + counts on the overlay           #
# --------------------------------------------------------------------------- #
def test_overlay_exposes_reasons_and_counts():
    ind = {"cmf": 0.2, "adx": 30, "close": 110.0, "ema20": 105.0,
           "ema50": 100.0, "ema200": 90.0, "rsi": 60}
    ov = explore.compute_overlay(60.0, [C.bullish], ind)
    assert ov["confirmations_total"] == 8
    assert ov["confirmations_fired"] == 4  # cmf, adx, trend, rsi
    reasons = ov["conviction_reasons"]
    assert len(reasons) == 4
    # Strongest-weight signals lead (cmf/adx = 4 pts before trend = 3).
    assert reasons[0] in (
        explore._CONVICTION_LABELS["cmf"], explore._CONVICTION_LABELS["adx"],
    )


def test_illiquid_overlay_has_empty_reasons():
    ind = {"cmf": 0.2, "adx": 30}
    ov = explore.compute_overlay(60.0, [C.bullish], ind, allow_bonus=False)
    assert ov["conviction_reasons"] == []
    assert ov["confirmations_fired"] == 0
    assert ov["trade_ready"] is False


# --------------------------------------------------------------------------- #
# Phase 12 (Task C) — trade-ready confluence gate                             #
# --------------------------------------------------------------------------- #
def test_trade_ready_requires_confluence():
    strong = {
        "cmf": 0.2, "obv": 10, "obv_prev": 5, "adx": 30,
        "macd": 1.0, "macd_signal": 0.5, "rsi": 60,
        "close": 110.0, "ema20": 105.0, "ema50": 100.0, "ema200": 90.0,
    }
    assert explore.is_trade_ready([C.bullish], strong) is True
    # Not bullish/pullback category -> never trade-ready.
    assert explore.is_trade_ready([C.accumulation], strong) is False
    # No uptrend structure -> not trade-ready.
    notrend = dict(strong, close=95.0)
    assert explore.is_trade_ready([C.bullish], notrend) is False
    # Overbought (RSI outside 50-75) -> not trade-ready.
    hot = dict(strong, rsi=85.0)
    assert explore.is_trade_ready([C.bullish], hot) is False
    # Too few confirmations -> not trade-ready.
    thin = {"close": 110.0, "ema20": 105.0, "ema50": 100.0, "ema200": 90.0,
            "rsi": 60}
    assert explore.is_trade_ready([C.bullish], thin) is False
