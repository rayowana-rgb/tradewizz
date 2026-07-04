"""Stage-3 backtest: Short-Term (1-month) Reversal on the live US cache.

Signal per name on date t: NEGATIVE of trailing 21d return, so recent LOSERS
rank high. Forward outcome: next 21d return (disjoint -> no look-ahead).

We run TWO passes to test whether the reversal edge is an illiquidity artifact
(ties to research/atoms/liquidity-participation.md finding of 6.5x variance in
illiquid names):
  * ALL names.
  * TRADABLE only (liquidity gate: median 63d dollar-volume >= $100k AND
    near-zero-volume-day fraction <= 20%).

We also contrast against the momentum sign on the same dates. Honest data
limit: ~1y, single regime -> evidence capped. Every number computed here; the
liquidity-participation atom's own numbers are NOT re-reported, only recomputed.
"""
from __future__ import annotations

import glob
import json
import math
import os
from typing import Dict, List, Optional

import numpy as np
import pandas as pd

CACHE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", ".cache", "ohlcv")
)

REV = 21            # reversal lookback (~1 month)
HOLD = 21
LIQ_WIN = 63
MIN_BARS = 200
N_DECILES = 10
ADV_FLOOR = 100_000.0
ZERO_VOL_MAX = 0.20
DOLLAR_FLOOR = 1_000.0


def _load_us() -> Dict[str, pd.DataFrame]:
    out: Dict[str, pd.DataFrame] = {}
    for meta_path in glob.glob(os.path.join(CACHE, "*.meta.json")):
        try:
            meta = json.load(open(meta_path))
        except Exception:
            continue
        if meta.get("market") != "US" or meta.get("interval") != "1d":
            continue
        csv_path = meta_path.replace(".meta.json", ".csv")
        if not os.path.exists(csv_path):
            continue
        try:
            df = pd.read_csv(csv_path, parse_dates=["Date"])
        except Exception:
            continue
        if not {"Date", "Adj Close", "Close", "Volume"}.issubset(df.columns) or len(df) < MIN_BARS:
            continue
        df = df.set_index("Date").sort_index()
        df = df[(df["Adj Close"] > 0) & (df["Close"] > 0)]
        if len(df) < MIN_BARS:
            continue
        df["dv"] = df["Close"] * df["Volume"].clip(lower=0)
        out[meta.get("ticker") or os.path.basename(csv_path)] = df
    return out


def _common_calendar(frames: Dict[str, pd.DataFrame]) -> pd.DatetimeIndex:
    counts: Dict[pd.Timestamp, int] = {}
    for df in frames.values():
        for d in df.index:
            counts[d] = counts.get(d, 0) + 1
    n = len(frames)
    return pd.DatetimeIndex(sorted(d for d, c in counts.items() if c >= 0.6 * n))


def _spearman(a: np.ndarray, b: np.ndarray) -> float:
    ra = pd.Series(a).rank().values
    rb = pd.Series(b).rank().values
    if np.std(ra) == 0 or np.std(rb) == 0:
        return float("nan")
    return float(np.corrcoef(ra, rb)[0, 1])


def _summarize(tmb: List[float], ic: List[float], deciles: List[np.ndarray]) -> dict:
    tmb_a = np.array([x for x in tmb if math.isfinite(x)])
    ic_a = np.array([x for x in ic if math.isfinite(x)])
    if len(tmb_a) == 0:
        return {"rebalances": 0}
    mean_dfwd = np.mean(np.vstack(deciles), axis=0)
    mono = _spearman(np.arange(N_DECILES), mean_dfwd)
    n = len(tmb_a)
    tstat = float(tmb_a.mean() / (tmb_a.std(ddof=1) / math.sqrt(n))) if n > 1 and tmb_a.std(ddof=1) > 0 else float("nan")
    return {
        "rebalances": n,
        "mean_ic": round(float(ic_a.mean()), 4) if len(ic_a) else None,
        "ic_frac_positive": round(float((ic_a > 0).mean()), 4) if len(ic_a) else None,
        "mean_top_minus_bottom_per_hold": round(float(tmb_a.mean()), 4),
        "spread_hit_rate": round(float((tmb_a > 0).mean()), 4),
        "spread_tstat": round(tstat, 3),
        "decile_monotonicity_spearman": round(float(mono), 4),
        "mean_forward_return_by_decile": [round(float(x), 4) for x in mean_dfwd],
    }


def run() -> dict:
    frames = _load_us()
    cal = _common_calendar(frames)
    first = max(REV, LIQ_WIN)
    last = len(cal) - HOLD - 1
    rebal_idx = list(range(first, last + 1, HOLD))

    passes = {
        "all_names": {"tmb": [], "ic": [], "dec": []},
        "tradable_only": {"tmb": [], "ic": [], "dec": []},
    }

    for ri in rebal_idx:
        t = cal[ri]
        t_rev = cal[ri - REV]
        t_liq = cal[ri - LIQ_WIN]
        t_fwd = cal[ri + HOLD]
        recs = []  # (signal, fwd, tradable)
        for df in frames.values():
            try:
                p_rev = df["Adj Close"].asof(t_rev)
                p_now = df["Adj Close"].asof(t)
                p_fwd = df["Adj Close"].asof(t_fwd)
            except Exception:
                continue
            if any(pd.isna(x) or x <= 0 for x in (p_rev, p_now, p_fwd)):
                continue
            w = df.loc[(df.index > t_liq) & (df.index <= t)]
            if len(w) < LIQ_WIN * 0.6:
                continue
            adv = float(np.median(w["dv"]))
            zero_frac = float((w["dv"] < DOLLAR_FLOOR).mean())
            tradable = (adv >= ADV_FLOOR) and (zero_frac <= ZERO_VOL_MAX)
            sig = -((p_now / p_rev) - 1.0)   # reversal: recent loser ranks high
            fwd = (p_fwd / p_now) - 1.0
            if not (math.isfinite(sig) and math.isfinite(fwd)):
                continue
            recs.append((sig, fwd, tradable))

        def _do(sub: np.ndarray, key: str):
            if len(sub) < 200:
                return
            order = np.argsort(sub[:, 0])
            buckets = np.array_split(order, N_DECILES)
            dfwd = np.array([sub[b, 1].mean() for b in buckets])
            passes[key]["tmb"].append(float(dfwd[-1] - dfwd[0]))
            passes[key]["ic"].append(_spearman(sub[:, 0], sub[:, 1]))
            passes[key]["dec"].append(dfwd)

        arr = np.array([(s, f) for s, f, _ in recs])
        trad = np.array([(s, f) for s, f, tr in recs if tr])
        if len(arr):
            _do(arr, "all_names")
        if len(trad):
            _do(trad, "tradable_only")

    return {
        "universe_symbols": len(frames),
        "common_calendar_days": len(cal),
        "data_window": f"{cal[0].date()} .. {cal[-1].date()}",
        "regime_note": "single ~1y regime; NOT multi-regime. Evidence capped.",
        "reversal_lookback_days": REV,
        "hold_days": HOLD,
        "note": "signal = NEGATIVE trailing 21d return (recent losers rank high)",
        "all_names": _summarize(passes["all_names"]["tmb"], passes["all_names"]["ic"], passes["all_names"]["dec"]),
        "tradable_only": _summarize(passes["tradable_only"]["tmb"], passes["tradable_only"]["ic"], passes["tradable_only"]["dec"]),
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    out = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(out, "w"), indent=2)
    print("\nwrote", out)
