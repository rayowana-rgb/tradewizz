"""Stage-3: multi-horizon momentum -- does blending 6-1 and 12-1 (two
ALPHA-BEARING, possibly-orthogonal signals) raise combined significance?

Follows the validated decorrelation METHOD from momentum-lowvol-combo, but with
a partner that actually HAS alpha (another momentum horizon) rather than low-vol.

Two long-only books, both top-10 / monthly / no-tight-stop / net 10bps/side:
  - MOM_12_1: 12-1 (252d return skip 21d)   -- the validated production signal
  - MOM_6_1 : 6-1  (126d return skip 21d)    -- medium-term momentum

We report, net of cost, TRAIN(<2017)/TEST(>=2017)/FULL:
  - each book stand-alone + excess over benchmark
  - correlation between the two books' per-rebalance returns
  - a 50/50 blend + its excess over benchmark

CRITICAL TEST: is blend excess-t > the 12-1 single-book excess-t? If yes, the
decorrelation method converts orthogonality into HIGHER combined significance
with an alpha-bearing partner. If the horizons are too redundant (high corr),
we record honestly that within-family horizon diversification adds little.
No fabricated numbers.
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

LB_LONG = 252   # 12-1 lookback
LB_MED = 126    # 6-1 lookback
SKIP = 21
HOLD = 21
LIQ_WIN = 63
MIN_BARS = 300
ADV_FLOOR = 100_000.0
ZERO_VOL_MAX = 0.20
DOLLAR_FLOOR = 1_000.0
TOP_N = 10
COST_BPS = 10.0
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
    first = LB_LONG + SKIP
    last = len(cal) - HOLD - 1

    recs = []
    for ri in range(first, last + 1, HOLD):
        t = cal[ri]
        t_l0, t_m0 = cal[ri - LB_LONG - SKIP], cal[ri - LB_MED - SKIP]
        t1 = cal[ri - SKIP]
        t_liq, t_fwd = cal[ri - LIQ_WIN], cal[ri + HOLD]
        rows = []
        for tkr, df in frames.items():
            pl0 = df["Adj Close"].asof(t_l0); pm0 = df["Adj Close"].asof(t_m0)
            p1 = df["Adj Close"].asof(t1)
            pn = df["Adj Close"].asof(t); pf = df["Adj Close"].asof(t_fwd)
            if any(pd.isna(x) or x <= 0 for x in (pl0, pm0, p1, pn, pf)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            mom12 = (p1 / pl0) - 1.0
            mom6 = (p1 / pm0) - 1.0
            fwd = (pf / pn) - 1.0
            rows.append((tkr, mom12, mom6, fwd))
        if len(rows) < 40:
            continue
        toks = np.array([r[0] for r in rows])
        m12 = np.array([r[1] for r in rows])
        m6 = np.array([r[2] for r in rows])
        fwd = np.array([r[3] for r in rows])
        sel12 = set(toks[np.argsort(m12)[-TOP_N:]].tolist())
        sel6 = set(toks[np.argsort(m6)[-TOP_N:]].tolist())
        fwd_by = {tk: f for tk, f in zip(toks, fwd)}
        recs.append({
            "ri": ri, "year": t.year,
            "sel12": sel12, "sel6": sel6, "fwd_by": fwd_by,
            "bench": float(np.mean(fwd)),
            "overlap": len(sel12 & sel6),
        })

    def _book(rr, key):
        prev = set(); out = []
        for r in rr:
            sel = r[key]
            ret = float(np.mean([r["fwd_by"][tk] for tk in sel]))
            turn = (len(prev.symmetric_difference(sel)) / 2.0 if prev else len(sel)) / max(len(sel), 1)
            out.append(ret - 2 * c * turn)
            prev = sel
        return out

    def build(split):
        if split == "train":
            rr = [r for r in recs if r["year"] < SPLIT_YEAR]
        elif split == "test":
            rr = [r for r in recs if r["year"] >= SPLIT_YEAR]
        else:
            rr = recs
        b12 = _book(rr, "sel12")
        b6 = _book(rr, "sel6")
        bench = [r["bench"] - 2 * c * 0.5 for r in rr]
        blend = [0.5 * a + 0.5 * b for a, b in zip(b12, b6)]
        corr = None
        if len(b12) > 2:
            cc = np.corrcoef(b12, b6)[0, 1]
            corr = round(float(cc), 3) if math.isfinite(cc) else None
        avg_overlap = round(float(np.mean([r["overlap"] for r in rr])), 2) if rr else None
        return {
            "n_rebalances": len(rr),
            "corr_12_6": corr,
            "avg_name_overlap_of_10": avg_overlap,
            "mom_12_1": _summ(b12),
            "mom_6_1": _summ(b6),
            "blend_50_50": _summ(blend),
            "excess_12_1": _summ([a - b for a, b in zip(b12, bench)]),
            "excess_6_1": _summ([a - b for a, b in zip(b6, bench)]),
            "excess_blend": _summ([a - b for a, b in zip(blend, bench)]),
        }

    return {
        "universe_symbols": len(frames),
        "total_rebalances": len(recs),
        "top_n": TOP_N,
        "split_year": SPLIT_YEAR,
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
