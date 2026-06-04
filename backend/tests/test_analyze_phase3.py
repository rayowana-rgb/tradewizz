"""Phase 3: analyze() refinement outputs (no network).

Buy reasons, support/resistance, trailing stop, profit-probability placeholder,
recommendation. All are additive/optional so the API contract is preserved.
"""

import tempfile

import numpy as np
import pandas as pd

from app.engine import AnalysisEngine
from app.ml import ProfitModel
from app.models import AnalysisResult, Market, ScreenerCategory

# Isolated model dir so these tests don't train into the repo cache.
_MODEL_DIR = tempfile.mkdtemp(prefix="tw_phase3_models_")


def make_df(close, high=None, low=None, volume=None):
    close = np.asarray(close, dtype="float64")
    n = len(close)
    high = close + 1.0 if high is None else np.asarray(high, "float64")
    low = close - 1.0 if low is None else np.asarray(low, "float64")
    volume = np.full(n, 1000.0) if volume is None else np.asarray(volume, "float64")
    return pd.DataFrame(
        {"Open": close, "High": high, "Low": low, "Close": close, "Volume": volume}
    )


def uptrend(n=300):
    return make_df(100 + np.arange(n) * 1.0)


def downtrend(n=300):
    return make_df(400 - np.arange(n) * 1.0)


def _engine(df):
    return AnalysisEngine(
        fetcher=lambda t, p, i: df,
        profit_model=ProfitModel(models_dir=_MODEL_DIR),
    )


# --- contract preservation --------------------------------------------------

def test_analyze_keeps_core_contract_fields():
    r = _engine(uptrend()).analyze("TEST", Market.IDX)
    # Existing required fields unchanged.
    for f in ("symbol", "market", "signal", "score", "summary",
              "highlights", "generated_at"):
        assert hasattr(r, f)
    assert r.signal in {"BUY", "HOLD", "SELL"}
    assert 0 <= r.score <= 100


def test_phase3_fields_present_and_typed():
    r = _engine(uptrend()).analyze("TEST", Market.IDX)
    assert isinstance(r.recommendation, str) and r.recommendation
    assert isinstance(r.buy_reasons, list)
    assert r.trailing_stop_percent is not None
    assert r.trailing_stop_price is not None
    assert 0.0 <= r.profit_probability <= 1.0
    assert r.support_resistance is not None


def test_analyzeresult_defaults_are_backward_compatible():
    # A minimal payload (old server shape) must still validate.
    r = AnalysisResult(
        symbol="X", market=Market.IDX, signal="HOLD", score=50,
        generated_at="2026-06-04T00:00:00Z",
    )
    assert r.buy_reasons == []
    assert r.recommendation == ""
    assert r.support_resistance is None
    assert r.profit_probability is None


# --- buy reasons (OBV/CMF/A-D/VWAP/MACD confirmation) ------------------------

def test_buy_reasons_on_uptrend_include_confirmations():
    r = _engine(uptrend()).analyze("UP", Market.IDX)
    text = " ".join(r.buy_reasons)
    # A steady uptrend should confirm at least MACD and VWAP.
    assert "MACD bullish" in text
    assert "Above VWAP" in text


def test_buy_reasons_empty_on_downtrend():
    r = _engine(downtrend()).analyze("DN", Market.IDX)
    # Falling market: no bullish confirmations.
    assert "MACD bullish" not in " ".join(r.buy_reasons)


# --- support / resistance ---------------------------------------------------

def test_support_resistance_levels_ordered():
    r = _engine(uptrend()).analyze("UP", Market.IDX)
    sr = r.support_resistance
    assert sr.immediate_support <= sr.immediate_resistance
    assert sr.major_support <= sr.major_resistance
    # Major window (50) is wider than immediate (10).
    assert sr.major_support <= sr.immediate_support
    assert sr.major_resistance >= sr.immediate_resistance


# --- trailing stop (ADX-banded; tighter for scalping) -----------------------

def test_trailing_stop_price_below_close():
    df = uptrend()
    eng = _engine(df)
    r = eng.analyze("UP", Market.IDX)
    assert r.trailing_stop_price < df["Close"].iloc[-1]
    assert r.trailing_stop_percent in (5, 7, 8, 10)  # non-scalping bands


def test_trailing_stop_tighter_for_scalping():
    eng = AnalysisEngine()
    base = {"close": 100.0, "adx": 15.0}
    pct_non, _ = eng._trailing_stop(base, cats=[])
    pct_scalp, _ = eng._trailing_stop(
        base, cats=[ScreenerCategory.scalping]
    )
    assert pct_scalp < pct_non  # 2 vs 5 at adx<20


def test_trailing_stop_widens_with_adx():
    eng = AnalysisEngine()
    weak, _ = eng._trailing_stop({"close": 100.0, "adx": 10.0}, [])
    strong, _ = eng._trailing_stop({"close": 100.0, "adx": 45.0}, [])
    assert strong > weak


# --- profit probability placeholder -----------------------------------------

def test_profit_probability_tracks_score():
    eng = AnalysisEngine()
    assert eng._profit_probability_placeholder(80) == 0.8
    assert eng._profit_probability_placeholder(0) == 0.0
    assert eng._profit_probability_placeholder(100) == 1.0


# --- recommendation ---------------------------------------------------------

def test_recommendation_matches_signal():
    eng = AnalysisEngine()
    assert eng._recommendation("BUY", [ScreenerCategory.bullish]).startswith("BUY")
    assert eng._recommendation("SELL", []).startswith("SELL")
    assert eng._recommendation("HOLD", []).startswith("HOLD")


# --- fallback path keeps optional fields at defaults ------------------------

def test_mock_fallback_has_no_phase3_fields():
    def boom(t, p, i):
        raise ConnectionError("offline")

    r = AnalysisEngine(fetcher=boom).analyze("ZZZ", Market.IDX)
    # Mock fallback is valid and simply omits the optional refinements.
    assert r.signal in {"BUY", "HOLD", "SELL"}
    assert r.buy_reasons == []
    assert r.support_resistance is None
    assert r.profit_probability is None
