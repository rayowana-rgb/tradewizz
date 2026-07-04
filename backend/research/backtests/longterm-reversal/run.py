"""Stage-3: LONG-TERM REVERSAL (DeBondt-Thaler) as a genuine decorrelation
partner for momentum.

Motivation: our best diversifiers so far were alpha-bearing but too CORRELATED
with 12-1 (6-1: 0.87, residual: 0.91). Long-term reversal selects the OPPOSITE
kind of name -- multi-year LOSERS that tend to mean-revert -- so by construction
it should be LOW or NEGATIVELY correlated with momentum (which buys winners).
If it ALSO carries alpha, it is the true decorrelation partner we've been after.

Signal: rank by trailing ~5-year return, SKIPPING the most recent 12 months (to
avoid overlap with 6-1/12-1 momentum), and go long the LOWEST (biggest losers).
Long-only top-10 / monthly / no-tight-stop / net 10bps/side.

Compared, net cost, TRAIN(<2017)/TEST(>=2017)/FULL, against the same tradable
universe restricted to names with enough history (>= ~6y):
  - MOM_12_1     : raw 12-1 momentum (validated production signal)
  - LT_REVERSAL  : long the 5y losers (skip last 12m)
  - correlation between the two books' per-rebalance returns  (key: LOW/NEG?)
  - 50/50 blend + excess over benchmark

CRITICAL TESTS:
  (1) does LT_REVERSAL carry alpha (excess-t > 0)?
  (2) is corr(12-1, reversal) LOW or NEGATIVE (unlike 6-1/resid)?
  (3) if both yes: does the blend lift Sharpe/significance meaningfully?
No fabricated numbers -- if reversal has no alpha OR isn't decorrelated, say so.
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

MOM_LB = 252            # 12-1 momentum lookback
MOM_SKIP = 21
REV_LB = 252 * 5        # ~5y reversal lookback
REV_SKIP = 252          # skip most recent 12 months
HOLD = 21
LIQ_WIN = 63
MIN_BARS = REV_LB + REV_SKIP + 60   # need enough history for the 5y window
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
    first = REV_LB + REV_SKIP
    last = len(cal) - HOLD - 1

    recs = []
    for ri in range(first, last + 1, HOLD):
        t = cal[ri]
        # momentum window
        tm0, tm1 = cal[ri - MOM_LB - MOM_SKIP], cal[ri - MOM_SKIP]
        # reversal window (skip last 12m)
        tr0, tr1 = cal[ri - REV_LB - REV_SKIP], cal[ri - REV_SKIP]
        t_liq, t_fwd = cal[ri - LIQ_WIN], cal[ri + HOLD]
        rows = []
        for tkr, df in frames.items():
            pm0 = df["Adj Close"].asof(tm0); pm1 = df["Adj Close"].asof(tm1)
            pr0 = df["Adj Close"].asof(tr0); pr1 = df["Adj Close"].asof(tr1)
            pn = df["Adj Close"].asof(t); pf = df["Adj Close"].asof(t_fwd)
            if any(pd.isna(x) or x <= 0 for x in (pm0, pm1, pr0, pr1, pn, pf)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            mom12 = (pm1 / pm0) - 1.0
            rev5 = (pr1 / pr0) - 1.0   # 5y return skipping last 12m
            fwd = (pf / pn) - 1.0
            rows.append((tkr, mom12, rev5, fwd))
        if len(rows) < 30:
            continue
        toks = np.array([r[0] for r in rows])
        m12 = np.array([r[1] for r in rows])
        rev = np.array([r[2] for r in rows])
        fwd = np.array([r[3] for r in rows])
        sel12 = set(toks[np.argsort(m12)[-TOP_N:]].tolist())    # winners
        selrev = set(toks[np.argsort(rev)[:TOP_N]].tolist())    # 5y losers
        fwd_by = {tk: f for tk, f in zip(toks, fwd)}
        recs.append({
            "ri": ri, "year": t.year,
            "sel12": sel12, "selrev": selrev, "fwd_by": fwd_by,
            "bench": float(np.mean(fwd)),
            "overlap": len(sel12 & selrev),
            "n_names": len(rows),
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
        brev = _book(rr, "selrev")
        bench = [r["bench"] - 2 * c * 0.5 for r in rr]
        blend = [0.5 * a + 0.5 * b for a, b in zip(b12, brev)]
        corr = None
        if len(b12) > 2:
            cc = np.corrcoef(b12, brev)[0, 1]
            corr = round(float(cc), 3) if math.isfinite(cc) else None
        avg_overlap = round(float(np.mean([r["overlap"] for r in rr])), 2) if rr else None
        avg_names = round(float(np.mean([r["n_names"] for r in rr])), 1) if rr else None
        return {
            "n_rebalances": len(rr),
            "corr_12_reversal": corr,
            "avg_name_overlap_of_10": avg_overlap,
            "avg_universe_names": avg_names,
            "mom_12_1": _summ(b12),
            "lt_reversal": _summ(brev),
            "blend_50_50": _summ(blend),
            "excess_12_1": _summ([a - b for a, b in zip(b12, bench)]),
            "excess_reversal": _summ([a - b for a, b in zip(brev, bench)]),
            "excess_blend": _summ([a - b for a, b in zip(blend, bench)]),
        }

    return {
        "universe_symbols": len(frames),
        "total_rebalances": len(recs),
        "top_n": TOP_N,
        "rev_lb_days": REV_LB,
        "rev_skip_days": REV_SKIP,
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
