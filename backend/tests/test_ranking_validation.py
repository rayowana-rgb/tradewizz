"""Phase 5: ranking-quality backtest validates that score predicts forward perf."""

from __future__ import annotations

import numpy as np
import pandas as pd

from app.models import Market
from app.ranking_validation import (
    BasketStats,
    run_ranking_backtest,
    _forward_return,
    _basket_stats,
)


def _series_df(closes, vol=5e9):
    closes = np.asarray(closes, dtype="float64")
    n = len(closes)
    return pd.DataFrame({
        "Open": closes, "High": closes + 1, "Low": closes - 1,
        "Close": closes, "Volume": np.full(n, vol),
    })


def _winner(seed):
    """A genuine uptrend that KEEPS rising after the as-of bar."""
    rng = np.random.default_rng(seed)
    base = 1000 + np.arange(300) * 6.0 + rng.normal(0, 6, 300)
    return _series_df(np.clip(base, 1, None), vol=8e10)


def _loser(seed):
    """A downtrend that keeps falling after the as-of bar."""
    rng = np.random.default_rng(seed)
    base = 5000 - np.arange(300) * 6.0 + rng.normal(0, 6, 300)
    return _series_df(np.clip(base, 1, None), vol=8e10)


def test_forward_return_positional():
    df = _series_df(np.arange(100, 200, dtype="float64"))  # +1/bar
    r = _forward_return(df["Close"], as_of=-22, horizon=21)
    assert r is not None and r > 0


def test_basket_stats_math():
    s = _basket_stats([0.10, 0.05, -0.02], benchmark_return=0.01)
    assert isinstance(s, BasketStats)
    assert s.n == 3
    assert abs(s.average_return - (0.13 / 3)) < 1e-9
    assert abs(s.win_rate - (2 / 3)) < 1e-9
    assert s.max_drawdown == -0.02
    assert s.excess_vs_benchmark == s.average_return - 0.01


def test_top_basket_outperforms_benchmark_and_losers():
    histories = {}
    for i in range(8):
        histories[f"WIN{i}"] = _winner(seed=i)
    for i in range(8):
        histories[f"LOSE{i}"] = _loser(seed=100 + i)

    # Benchmark: a mild uptrend (bull regime).
    bench = _series_df(np.clip(2000 + np.arange(300) * 1.0, 1, None))

    report = run_ranking_backtest(
        histories, Market.US, as_of=-22, horizon=21,
        benchmark=bench, top_ns=(10, 20),
    )

    # Winners should dominate the top of the ranking.
    top10_syms = [s for s, _ in report.ranked[:10]]
    assert sum(1 for s in top10_syms if s.startswith("WIN")) >= 7

    t10 = report.baskets["top_10"]
    # Top basket beats the benchmark forward return.
    assert report.benchmark_return is not None
    assert t10.average_return > report.benchmark_return
    assert t10.excess_vs_benchmark > 0
    # Mostly winning names, positive Sharpe.
    assert t10.win_rate >= 0.7
    assert t10.sharpe > 0


def test_report_to_dict_shape():
    histories = {f"WIN{i}": _winner(seed=i) for i in range(3)}
    report = run_ranking_backtest(histories, Market.US, top_ns=(10,))
    d = report.to_dict()
    assert "baskets" in d and "top_10" in d["baskets"]
    b = d["baskets"]["top_10"]
    for k in ("n", "average_return", "win_rate", "sharpe", "max_drawdown",
              "excess_vs_benchmark"):
        assert k in b
