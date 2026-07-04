"""Stage-3 sensitivity sweep for the long-only momentum production candidate.

Two questions that decide production viability:
  1. Cost robustness: does the excess edge survive higher trading costs
     (5 / 10 / 20 bps per side)? The app pays a flat ~$0.99/order on Moomoo SG;
     at $500/position that is ~20 bps, so 20 bps is the realistic upper bound.
  2. Concentration: how few names can we hold and keep the edge? The app buys
     ~10 names, so we test TOP_N in {10, 20, 34(full decile)}.

For each (cost, top_n) we report the long-only book net of cost vs the
equal-weight benchmark, both WITHOUT and WITH the winning per-position
stop-loss overlay (-15% monthly floor proxy). We reuse one pass over history
(compute per-name forward returns + ranks once) and apply the grid post hoc.
"""
from __future__ import annotations

import glob
import json
import math
import os
from collections import defaultdict
from typing import Dict, List

import numpy as np
import pandas as pd

CACHE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", ".cache", "ohlcv")
)

LOOKBACK = 252
SKIP = 21
HOLD = 21
LIQ_WIN = 63
MIN_BARS = 300
ADV_FLOOR = 100_000.0
ZERO_VOL_MAX = 0.20
DOLLAR_FLOOR = 1_000.0
STOP = 0.15
COSTS_BPS = [5.0, 10.0, 20.0]
TOP_NS = [10, 20, 34]


def _load_max_us() -> Dict[str, pd.DataFrame]:
    out: Dict[str, pd.DataFrame] = {}
    for mp in glob.glob(os.path.join(CACHE, "*.meta.json")):
        try:
            meta = json.load(open(mp))
        except Exception:
            continue
        if (meta.get("market") != "US" or meta.get("interval") != "1d"
                or meta.get("period") != "max"):
            continue
        csv = mp.replace(".meta.json", ".csv")
        if not os.path.exists(csv):
            continue
        try:
            df = pd.read_csv(csv, parse_dates=["Date"])
        except Exception:
            continue
        if not {"Date", "Adj Close", "Close", "Volume"}.issubset(df.columns) or len(df) < MIN_BARS:
            continue
        df = df.set_index("Date").sort_index()
        df = df[(df["Adj Close"] > 0) & (df["Close"] > 0)]
        if len(df) < MIN_BARS:
            continue
        df["dv"] = df["Close"] * df["Volume"].clip(lower=0)
        out[meta.get("ticker")] = df
    return out


def _common_calendar(frames) -> pd.DatetimeIndex:
    counts: Dict[pd.Timestamp, int] = defaultdict(int)
    for df in frames.values():
        for d in df.index:
            counts[d] += 1
    n = len(frames)
    return pd.DatetimeIndex(sorted(d for d, c in counts.items() if c >= 0.6 * n))


def _is_tradable(df, t_lo, t) -> bool:
    w = df.loc[(df.index > t_lo) & (df.index <= t)]
    if len(w) < LIQ_WIN * 0.6:
        return False
    adv = float(np.median(w["dv"]))
    zero_frac = float((w["dv"] < DOLLAR_FLOOR).mean())
    return (adv >= ADV_FLOOR) and (zero_frac <= ZERO_VOL_MAX)


def _summ(series: List[float]) -> dict:
    s = [x for x in series if x is not None and math.isfinite(x)]
    if not s:
        return {"n": 0}
    m = float(np.mean(s)); sd = float(np.std(s, ddof=1)) if len(s) > 1 else 0.0
    lvl = 1.0
    for x in s:
        lvl *= (1 + x)
    return {
        "mean_per_hold": round(m, 5),
        "worst": round(min(s), 4),
        "cum_return": round(lvl - 1.0, 2),
        "sharpe": round(m / sd * math.sqrt(12), 3) if sd > 0 else None,
    }


def run() -> dict:
    frames = _load_max_us()
    cal = _common_calendar(frames)
    first = LOOKBACK + SKIP
    last = len(cal) - HOLD - 1

    # single pass: store per-rebalance ranked forward returns
    passes = []  # each: {"ranked_fwd": np.array (sorted by momentum asc), "bench": float}
    for ri in range(first, last + 1, HOLD):
        t = cal[ri]
        t0, t1 = cal[ri - LOOKBACK - SKIP], cal[ri - SKIP]
        t_liq, t_fwd = cal[ri - LIQ_WIN], cal[ri + HOLD]
        momen, fwd, names = [], [], []
        for tkr, df in frames.items():
            p0 = df["Adj Close"].asof(t0); p1 = df["Adj Close"].asof(t1)
            pn = df["Adj Close"].asof(t); pf = df["Adj Close"].asof(t_fwd)
            if any(pd.isna(x) or x <= 0 for x in (p0, p1, pn, pf)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            momen.append((p1 / p0) - 1.0); fwd.append((pf / pn) - 1.0); names.append(tkr)
        if len(names) < 40:
            continue
        momen = np.array(momen); fwd = np.array(fwd); names = np.array(names)
        order = np.argsort(momen)
        passes.append({
            "fwd_by_mom": fwd[order],      # ascending momentum
            "names_by_mom": names[order],
            "bench": float(np.mean(fwd)),
        })

    grid = {}
    for topn in TOP_NS:
        # precompute per-rebalance top-N mean fwd and name-turnover
        top_ret, bench_ret, turns = [], [], []
        prev = set()
        for p in passes:
            sel_names = set(p["names_by_mom"][-topn:].tolist())
            sel_fwd = p["fwd_by_mom"][-topn:]
            top_ret.append(float(np.mean(sel_fwd)))
            bench_ret.append(p["bench"])
            chg = len(prev.symmetric_difference(sel_names)) / 2.0 if prev else len(sel_names)
            turns.append(chg / max(len(sel_names), 1))
            prev = sel_names
        for cost_bps in COSTS_BPS:
            c = cost_bps / 10000.0
            raw = [r - 2 * c * to for r, to in zip(top_ret, turns)]
            stop = [max(r, -STOP) - 2 * c * to for r, to in zip(top_ret, turns)]
            bench = [b - 2 * c * 0.5 for b in bench_ret]
            key = f"top{topn}_cost{int(cost_bps)}bps"
            grid[key] = {
                "raw_net": _summ(raw),
                "stop_net": _summ(stop),
                "excess_raw": _summ([a - b for a, b in zip(raw, bench)]),
                "excess_stop": _summ([a - b for a, b in zip(stop, bench)]),
            }

    return {
        "universe_symbols": len(frames),
        "rebalances": len(passes),
        "stop": STOP,
        "grid": grid,
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    p = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(p, "w"), indent=2)
    print("\nwrote", p)
