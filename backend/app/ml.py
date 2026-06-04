"""RandomForest profit classifier (ported from legacy bot9.py).

Trains a per-symbol binary classifier predicting whether a bar is "profitable"
(forward return over `threshold` within `forward_days`). The latest bar's
predicted P(profitable) becomes `AnalysisResult.profit_probability`.

Design:
- Pure offline training on the symbol's own OHLCV history (no network).
- Disk persistence (joblib) + lazy load, keyed by market+symbol+feature-version.
- Safe: any failure (too little data, single-class labels, sklearn error)
  returns None so the engine degrades gracefully (the field becomes optional).

Feature set mirrors the legacy `feature_cols` where the backend has the
indicator: RSI, MACD, MACD signal/hist, VWAP, SMA20/50/200, EMA20/50, OBV,
A/D, CMF, ADX, ATR, volume, volume ratio.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import List, Optional

import numpy as np
import pandas as pd

from . import indicators

logger = logging.getLogger("tradewiz.ml")

# Bump when the feature set changes so stale models are not reused.
FEATURE_VERSION = "v1"

# Forward-return labeling (legacy defaults).
FORWARD_DAYS = 3
THRESHOLD = 0.01  # +1% within FORWARD_DAYS == "profitable"

# Ordered feature columns produced by `build_feature_frame`.
FEATURE_COLS: List[str] = [
    "rsi", "macd", "macd_signal", "macd_hist",
    "vwap", "sma20", "sma50", "sma200", "ema20", "ema50",
    "obv", "ad", "cmf", "adx", "atr", "volume", "volume_ratio",
]


def _models_dir() -> Path:
    env = os.environ.get("TRADEWIZ_MODEL_DIR")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent / ".cache" / "rf_models"


def build_feature_frame(df: pd.DataFrame) -> pd.DataFrame:
    """Per-row feature frame aligned to `df.index` (NaNs during warm-up)."""
    close = df["Close"]
    volume = df["Volume"]
    macd_df = indicators.macd(close)
    feats = pd.DataFrame(index=df.index)
    feats["rsi"] = indicators.rsi(close)
    feats["macd"] = macd_df["macd"]
    feats["macd_signal"] = macd_df["signal"]
    feats["macd_hist"] = macd_df["hist"]
    feats["vwap"] = indicators.vwap(df)
    feats["sma20"] = indicators.sma(close, 20)
    feats["sma50"] = indicators.sma(close, 50)
    feats["sma200"] = indicators.sma(close, 200)
    feats["ema20"] = indicators.ema(close, 20)
    feats["ema50"] = indicators.ema(close, 50)
    feats["obv"] = indicators.obv(close, volume)
    feats["ad"] = indicators.accum_dist(df)
    feats["cmf"] = indicators.cmf(df)
    feats["adx"] = indicators.adx(df)
    feats["atr"] = indicators.atr(df)
    feats["volume"] = volume
    feats["volume_ratio"] = indicators.volume_ratio(volume)
    return feats[FEATURE_COLS]


def label_profitable(
    df: pd.DataFrame, forward_days: int = FORWARD_DAYS, threshold: float = THRESHOLD
) -> pd.Series:
    """Binary label: forward `forward_days` return exceeds `threshold`."""
    close = df["Close"]
    future = close.shift(-forward_days)
    ret = (future / close) - 1
    return (ret > threshold).astype("float64").where(ret.notna())


class ProfitModel:
    """Trains/caches/loads a RandomForest profit classifier per symbol."""

    def __init__(self, models_dir: Optional[Path | str] = None):
        self._dir = Path(models_dir) if models_dir else _models_dir()
        self._mem: dict = {}  # in-process cache: key -> fitted clf (or None)

    def _key(self, market: str, symbol: str) -> str:
        return f"{market}_{symbol}_{FEATURE_VERSION}".upper()

    def _path(self, key: str) -> Path:
        return self._dir / f"{key}.pkl"

    # -- training --------------------------------------------------------

    def _train(self, df: pd.DataFrame):
        """Fit a classifier on `df`; return it or None if not trainable."""
        try:
            from sklearn.ensemble import RandomForestClassifier
        except Exception as exc:  # noqa: BLE001 - sklearn missing -> skip
            logger.warning("sklearn unavailable: %s", exc)
            return None

        feats = build_feature_frame(df)
        labels = label_profitable(df)
        data = feats.join(labels.rename("y")).dropna()
        if len(data) < 60:
            return None  # not enough clean rows
        y = data["y"].astype(int)
        if y.nunique() < 2:
            return None  # single-class -> classifier is meaningless
        X = data[FEATURE_COLS]
        clf = RandomForestClassifier(n_estimators=100, random_state=42)
        clf.fit(X, y)
        return clf

    # -- persistence / lazy load ----------------------------------------

    def _load_or_train(self, market: str, symbol: str, df: pd.DataFrame):
        key = self._key(market, symbol)
        if key in self._mem:
            return self._mem[key]

        path = self._path(key)
        if path.exists():
            try:
                import joblib

                clf = joblib.load(path)
                self._mem[key] = clf
                return clf
            except Exception as exc:  # noqa: BLE001 - corrupt -> retrain
                logger.warning("model load failed (%s): %s", key, exc)

        clf = self._train(df)
        self._mem[key] = clf
        if clf is not None:
            try:
                import joblib

                self._dir.mkdir(parents=True, exist_ok=True)
                joblib.dump(clf, path)
            except Exception as exc:  # noqa: BLE001 - persist best-effort
                logger.warning("model persist failed (%s): %s", key, exc)
        return clf

    # -- public ----------------------------------------------------------

    def probability(
        self, df: pd.DataFrame, market: str, symbol: str
    ) -> Optional[float]:
        """P(profitable) for the latest bar, or None if unavailable."""
        try:
            clf = self._load_or_train(market, symbol, df)
            if clf is None:
                return None
            feats = build_feature_frame(df).dropna()
            if feats.empty:
                return None
            latest = feats.iloc[[-1]][FEATURE_COLS]
            proba = clf.predict_proba(latest)[0]
            classes = list(clf.classes_)
            if 1 in classes:
                p = float(proba[classes.index(1)])
            else:
                # Single-class model: classes_ == [0] -> P(profitable)=0.
                p = 1.0 if classes[0] == 1 else 0.0
            return round(max(0.0, min(1.0, p)), 4)
        except Exception as exc:  # noqa: BLE001 - never break analyze
            logger.warning("profit probability failed for %s: %s", symbol, exc)
            return None

    def clear(self) -> None:
        self._mem.clear()
