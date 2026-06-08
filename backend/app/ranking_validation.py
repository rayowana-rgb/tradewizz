"""Ranking-quality backtest (Phase 5).

Given a set of symbols' OHLCV histories, this:
  1. computes the institutional composite score *as of* a chosen as-of bar
     (using only data up to that bar -> no look-ahead);
  2. ranks symbols by score;
  3. measures the realized forward return of the Top-10 / Top-20 / Top-50
     baskets over a holding horizon;
  4. compares against the benchmark index forward return;
  5. reports Average Return, Win Rate, Sharpe Ratio, and Max Drawdown per basket.

It is a pure, offline analysis helper (no network) used by tests and by an
operator to confirm that higher scores actually select better forward
performers. It does not touch the live scoring path.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional

import numpy as np
import pandas as pd

from . import indicators, scoring
from .models import Market
from .scoring import MarketContext


@dataclass
class BasketStats:
    n: int
    average_return: float          # mean forward return (fraction)
    win_rate: float                # fraction of names with positive return
    sharpe: float                  # mean/std of the basket's returns
    max_drawdown: float            # most negative single-name return (fraction)
    excess_vs_benchmark: float     # average_return - benchmark_return

    def to_dict(self) -> dict:
        return {
            "n": self.n,
            "average_return": round(self.average_return, 6),
            "win_rate": round(self.win_rate, 4),
            "sharpe": round(self.sharpe, 4),
            "max_drawdown": round(self.max_drawdown, 6),
            "excess_vs_benchmark": round(self.excess_vs_benchmark, 6),
        }


@dataclass
class RankingReport:
    as_of: int
    horizon: int
    benchmark_return: Optional[float]
    ranked: List[tuple] = field(default_factory=list)  # (symbol, score)
    baskets: Dict[str, BasketStats] = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "as_of": self.as_of,
            "horizon": self.horizon,
            "benchmark_return": (
                None if self.benchmark_return is None
                else round(self.benchmark_return, 6)
            ),
            "ranked": [(s, round(sc, 2)) for s, sc in self.ranked],
            "baskets": {k: v.to_dict() for k, v in self.baskets.items()},
        }


def _forward_return(close: pd.Series, as_of: int, horizon: int) -> Optional[float]:
    """Return over [as_of, as_of+horizon] using positional indexing."""
    c = close.dropna().reset_index(drop=True)
    if as_of < 0:
        as_of = len(c) + as_of
    end = as_of + horizon
    if as_of < 0 or end >= len(c):
        return None
    p0 = float(c.iloc[as_of])
    p1 = float(c.iloc[end])
    if p0 == 0:
        return None
    return p1 / p0 - 1.0


def _score_as_of(
    df: pd.DataFrame,
    as_of: int,
    market: Market,
    ctx: Optional[MarketContext],
) -> Optional[float]:
    """Composite technical score computed from data up to `as_of` (inclusive)."""
    sub = df.iloc[: (as_of + 1)] if as_of >= 0 else df.iloc[: (len(df) + as_of + 1)]
    if len(sub) < 60:
        return None
    ind = indicators.compute_all(sub)
    if ind.get("close") is None:
        return None
    return scoring.technical_score(ind, ctx, market)


def _basket_stats(
    returns: List[float], benchmark_return: Optional[float]
) -> BasketStats:
    arr = np.asarray(returns, dtype="float64")
    n = len(arr)
    if n == 0:
        return BasketStats(0, 0.0, 0.0, 0.0, 0.0, 0.0)
    avg = float(arr.mean())
    win = float((arr > 0).mean())
    std = float(arr.std(ddof=0))
    sharpe = 0.0 if std == 0 else avg / std
    mdd = float(arr.min())
    excess = 0.0 if benchmark_return is None else avg - benchmark_return
    return BasketStats(n, avg, win, sharpe if math.isfinite(sharpe) else 0.0,
                       mdd, excess)


def run_ranking_backtest(
    histories: Dict[str, pd.DataFrame],
    market: Market,
    *,
    as_of: int = -22,            # ~1 month before the latest bar
    horizon: int = 21,           # ~1 month forward hold
    benchmark: Optional[pd.DataFrame] = None,
    contexts: Optional[Dict[str, MarketContext]] = None,
    top_ns: tuple = (10, 20, 50),
) -> RankingReport:
    """Rank `histories` by as-of score and measure forward basket performance.

    histories : symbol -> OHLCV DataFrame (chronological).
    benchmark : optional index OHLCV for the benchmark forward return + regime.
    contexts  : optional per-symbol MarketContext (relative strength/regime);
                if omitted, regime is derived from the benchmark and relative
                strength is left neutral.
    """
    contexts = contexts or {}

    # Benchmark forward return + regime (shared context fallback).
    benchmark_return = None
    shared_ctx = None
    if benchmark is not None and "Close" in benchmark:
        benchmark_return = _forward_return(benchmark["Close"], as_of, horizon)
        bclose = benchmark["Close"].dropna()
        e50 = indicators.ema(bclose, 50).dropna()
        e200 = indicators.ema(bclose, 200).dropna()
        regime = None
        if not e50.empty and not e200.empty:
            regime = "bull" if float(e50.iloc[-1]) >= float(e200.iloc[-1]) else "bear"
        shared_ctx = MarketContext(regime=regime)

    scored: List[tuple] = []
    fwd: Dict[str, float] = {}
    for sym, df in histories.items():
        ctx = contexts.get(sym, shared_ctx)
        score = _score_as_of(df, as_of, market, ctx)
        if score is None:
            continue
        r = _forward_return(df["Close"], as_of, horizon)
        if r is None:
            continue
        scored.append((sym, score))
        fwd[sym] = r

    scored.sort(key=lambda t: t[1], reverse=True)

    baskets: Dict[str, BasketStats] = {}
    for n in top_ns:
        top = scored[:n]
        rets = [fwd[s] for s, _ in top]
        baskets[f"top_{n}"] = _basket_stats(rets, benchmark_return)

    return RankingReport(
        as_of=as_of,
        horizon=horizon,
        benchmark_return=benchmark_return,
        ranked=scored,
        baskets=baskets,
    )
