"""Stage-3b OOS on the CORRECTED final long-only production spec.

Final spec after 2026-07-04d correction:
  - long-only, TOP-10 by 12-1 momentum, monthly rebalance
  - NO tight intraday stop (the monthly rebalance is the exit)
  - at most a WIDE disaster stop; we also report an SL-8% disaster-stop variant
    to check whether the "wide only" rule generalises out of sample.

There are NO fitted parameters in the base spec (pure momentum ranking), so the
train/test split here is an honest generalisation check of the EDGE across two
distinct regimes rather than a parameter-fitting exercise:
  TRAIN  = rebalances with year < 2017 (incl. 2008-09 GFC)
  TEST   = rebalances with year >= 2017 (incl. 2020 COVID crash + 2020-21 bull)

Reports, for each split: benchmark, top-10 no-stop, and top-10 with an SL-8%
disaster stop (intraday path-dependent, same conservative mechanics as
momentum-longonly-intraday-stop). Metric of record: excess-over-benchmark.
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
TOP_N = 10
COST_BPS = 10.0
DISASTER_SL = 0.08     # wide disaster stop; no take-profit (let winners run)
SPLIT_YEAR = 2017


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
        need = {"Date", "Adj Close", "Close", "Open", "High", "Low", "Volume"}
        if not need.issubset(df.columns) or len(df) < MIN_BARS:
            continue
        df = df.set_index("Date").sort_index()
        df = df[(df["Adj Close"] > 0) & (df["Close"] > 0)]
        if len(df) < MIN_BARS:
            continue
        df["adj_f"] = df["Adj Close"] / df["Close"]
        df["adjHigh"] = df["High"] * df["adj_f"]
        df["adjLow"] = df["Low"] * df["adj_f"]
        df["adjOpen"] = df["Open"] * df["adj_f"]
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


def _hold_with_disaster_stop(df, entry_t, cal, ri, sl) -> float:
    entry = df["Adj Close"].asof(entry_t)
    if pd.isna(entry) or entry <= 0:
        return None
    stop_level = entry * (1 - sl)
    for k in range(1, HOLD + 1):
        row_idx = df.index.asof(cal[ri + k])
        if row_idx is None or pd.isna(row_idx) or row_idx not in df.index:
            continue
        o = df.at[row_idx, "adjOpen"]; lo = df.at[row_idx, "adjLow"]
        if pd.isna(o) or pd.isna(lo):
            continue
        if o <= stop_level:
            return o / entry - 1.0
        if lo <= stop_level:
            return -sl
    exit_p = df["Adj Close"].asof(cal[ri + HOLD])
    if pd.isna(exit_p) or exit_p <= 0:
        return None
    return exit_p / entry - 1.0


def _summ(series: List[float]) -> dict:
    s = [x for x in series if x is not None and math.isfinite(x)]
    if not s:
        return {"n": 0}
    m = float(np.mean(s)); sd = float(np.std(s, ddof=1)) if len(s) > 1 else 0.0
    t = m / (sd / math.sqrt(len(s))) if sd > 0 else None
    lvl = 1.0
    for x in s:
        lvl *= (1 + x)
    return {
        "n": len(s),
        "mean_per_hold": round(m, 5),
        "t_stat": round(t, 3) if t is not None else None,
        "worst": round(min(s), 4),
        "cum_return": round(lvl - 1.0, 2),
        "sharpe": round(m / sd * math.sqrt(12), 3) if sd > 0 else None,
    }


def run() -> dict:
    frames = _load_max_us()
    cal = _common_calendar(frames)
    c = COST_BPS / 10000.0
    first = LOOKBACK + SKIP
    last = len(cal) - HOLD - 1

    recs = []
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
        sel = names[order[-TOP_N:]].tolist()
        recs.append({"ri": ri, "t": t, "year": t.year, "sel": sel, "bench": float(np.mean(fwd))})

    def build(split):
        if split == "train":
            rr = [r for r in recs if r["year"] < SPLIT_YEAR]
        elif split == "test":
            rr = [r for r in recs if r["year"] >= SPLIT_YEAR]
        else:
            rr = recs
        bench, nostop, disaster = [], [], []
        for r in rr:
            bench.append(r["bench"] - 2 * c * 0.5)
            v_no, v_ds = [], []
            for tkr in r["sel"]:
                df = frames[tkr]
                pn = df["Adj Close"].asof(r["t"]); pf = df["Adj Close"].asof(cal[r["ri"] + HOLD])
                if pd.notna(pn) and pd.notna(pf) and pn > 0:
                    v_no.append(pf / pn - 1.0)
                hr = _hold_with_disaster_stop(df, r["t"], cal, r["ri"], DISASTER_SL)
                if hr is not None:
                    v_ds.append(hr)
            if v_no:
                nostop.append(float(np.mean(v_no)) - 2 * c * 1.0)
            if v_ds:
                disaster.append(float(np.mean(v_ds)) - 2 * c * 1.0)
        return {
            "n_rebalances": len(rr),
            "benchmark": _summ(bench),
            "top10_no_stop": _summ(nostop),
            "top10_disaster_sl8": _summ(disaster),
            "excess_no_stop": _summ([a - b for a, b in zip(nostop, bench)]),
            "excess_disaster": _summ([a - b for a, b in zip(disaster, bench)]),
        }

    return {
        "universe_symbols": len(frames),
        "total_rebalances": len(recs),
        "split_year": SPLIT_YEAR,
        "top_n": TOP_N,
        "cost_bps_per_side": COST_BPS,
        "disaster_sl": DISASTER_SL,
        "full": build("full"),
        "train": build("train"),
        "test": build("test"),
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    p = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(p, "w"), indent=2)
    print("\nwrote", p)
