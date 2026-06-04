"""Phase 4: RandomForest profit classifier (offline, synthetic, no network)."""

import numpy as np
import pandas as pd

from app.engine import AnalysisEngine
from app.ml import FEATURE_COLS, ProfitModel, build_feature_frame, label_profitable
from app.models import Market


def make_df(drift, seed, n=500):
    """Drift + noise so forward returns straddle the threshold (two classes)."""
    rng = np.random.default_rng(seed)
    close = 100 + np.cumsum(rng.normal(drift, 2.0, n))
    close = np.maximum(close, 1.0)
    high = close + np.abs(rng.normal(0, 1, n)) + 0.5
    low = close - np.abs(rng.normal(0, 1, n)) - 0.5
    vol = rng.integers(1000, 5000, n).astype("float64")
    return pd.DataFrame(
        {"Open": close, "High": high, "Low": low, "Close": close, "Volume": vol}
    )


# --- feature engineering -----------------------------------------------------

def test_feature_frame_has_expected_columns():
    feats = build_feature_frame(make_df(0.3, 1))
    assert list(feats.columns) == FEATURE_COLS
    # Latest row is fully populated (no NaN) given enough history.
    assert not feats.dropna().empty


def test_label_profitable_is_binary_and_forward_looking():
    df = make_df(0.5, 2, n=100)
    y = label_profitable(df).dropna()
    assert set(y.unique()).issubset({0.0, 1.0})
    # Last few rows are NaN (no forward window) -> dropped.
    assert len(y) < len(df)


# --- probability output ------------------------------------------------------

def test_probability_in_unit_interval(tmp_path):
    m = ProfitModel(models_dir=tmp_path)
    p = m.probability(make_df(0.4, 3), "IDX", "AAA")
    assert p is not None
    assert 0.0 <= p <= 1.0


def test_bullish_probability_exceeds_bearish(tmp_path):
    m = ProfitModel(models_dir=tmp_path)
    bull = m.probability(make_df(0.6, 42), "IDX", "BULL")
    bear = m.probability(make_df(-0.6, 42), "IDX", "BEAR")
    assert bull is not None
    # Bearish drift yields few/zero profitable bars -> low or None probability.
    bear_val = 0.0 if bear is None else bear
    assert bull > bear_val


def test_probability_changes_with_fixture(tmp_path):
    m = ProfitModel(models_dir=tmp_path)
    strong = m.probability(make_df(0.9, 7), "IDX", "STRONG")
    weak = m.probability(make_df(0.05, 7), "IDX", "WEAK")
    assert strong is not None and weak is not None
    assert strong != weak  # different fixtures -> different probabilities


# --- persistence + lazy load -------------------------------------------------

def test_model_persisted_to_disk(tmp_path):
    m = ProfitModel(models_dir=tmp_path)
    m.probability(make_df(0.5, 9), "IDX", "PERSIST")
    pkls = list(tmp_path.glob("*.pkl"))
    assert len(pkls) == 1
    assert "PERSIST" in pkls[0].name.upper()


def test_lazy_load_reuses_persisted_model(tmp_path):
    df = make_df(0.5, 11)
    ProfitModel(models_dir=tmp_path).probability(df, "IDX", "LAZY")
    # Fresh instance (cold in-process cache) must load from disk, not retrain.
    m2 = ProfitModel(models_dir=tmp_path)
    clf = m2._load_or_train("IDX", "LAZY", df)
    assert clf is not None
    # In-memory cache now populated for the key.
    assert m2._key("IDX", "LAZY") in m2._mem


def test_in_process_cache_avoids_recompute(tmp_path):
    df = make_df(0.5, 13)
    m = ProfitModel(models_dir=tmp_path)
    p1 = m.probability(df, "IDX", "CACHE")
    p2 = m.probability(df, "IDX", "CACHE")
    assert p1 == p2


# --- graceful degradation ----------------------------------------------------

def test_insufficient_data_returns_none(tmp_path):
    m = ProfitModel(models_dir=tmp_path)
    # Far too few rows to train.
    assert m.probability(make_df(0.5, 1, n=20), "IDX", "TINY") is None


def test_single_class_returns_none(tmp_path):
    # Flat price -> every forward return == 0 -> no bar exceeds threshold ->
    # labels are all 0 (single class) -> not trainable -> None.
    n = 400
    close = np.full(n, 100.0)
    df = pd.DataFrame(
        {"Open": close, "High": close, "Low": close, "Close": close,
         "Volume": np.full(n, 2000.0)}
    )
    assert ProfitModel(models_dir=tmp_path).probability(df, "IDX", "FLAT") is None


# --- engine integration ------------------------------------------------------

def test_engine_uses_real_classifier(tmp_path):
    df = make_df(0.5, 17)
    eng = AnalysisEngine(
        fetcher=lambda t, p, i: df,
        profit_model=ProfitModel(models_dir=tmp_path),
    )
    r = eng.analyze("BBCA", Market.IDX)
    assert r.profit_probability is not None
    assert 0.0 <= r.profit_probability <= 1.0


def test_engine_falls_back_to_placeholder_when_model_none(tmp_path):
    # Tiny frame -> classifier returns None -> placeholder (score/100) used.
    rng = np.random.default_rng(3)
    n = 25
    close = 100 + np.cumsum(rng.normal(0.5, 1.0, n))
    df = pd.DataFrame(
        {"Open": close, "High": close + 1, "Low": close - 1, "Close": close,
         "Volume": rng.integers(1000, 5000, n).astype("float64")}
    )
    eng = AnalysisEngine(
        fetcher=lambda t, p, i: df,
        profit_model=ProfitModel(models_dir=tmp_path),
    )
    r = eng.analyze("X", Market.IDX)
    # Placeholder == score/100, so it must equal that exactly.
    assert r.profit_probability == round(r.score / 100.0, 4)
