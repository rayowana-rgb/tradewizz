"""Stage-3: CONDITIONAL crash-recovery tilt (momentum + long-term reversal).

Open hypothesis from longterm-reversal.md: reversal is strongest exactly when
momentum is weakest (TRAIN/GFC). A static 50/50 blend DILUTES momentum, but a
SMALL or REGIME-CONDITIONAL tilt toward reversal might add drawdown resilience
without much return give-up. This test either confirms that or kills it.

Same universe/gates/costs as longterm-reversal (>= ~6y history), so results are
directly comparable to that run.

Books (all long-only top-10 monthly, net 10bps/side):
  - MOM         : pure 12-1 momentum (the production candidate)
  - REV         : pure 5y reversal (skip 12m)
  - TILT_90_10  : static 90% MOM / 10% REV per-rebalance return blend
  - TILT_80_20  : static 80% MOM / 20% REV
  - REGIME      : regime-switched -- when equal-weight market is BELOW its 200d
                  SMA at the rebalance ("bear/crisis"), use 60/40 MOM/REV;
                  otherwise 100% MOM. (Reversal only leans in during stress.)

Reports per split (TRAIN<2017/TEST>=2017/FULL), net cost:
  each book's mean/t/worst-DD/cum/Sharpe AND excess over benchmark.
DECISION RULE (honest): a tilt "wins" only if it improves worst-DD AND does NOT
reduce excess-t / Sharpe vs pure momentum. Otherwise pure momentum wins clean.
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

MOM_LB = 252
MOM_SKIP = 21
REV_LB = 252 * 5
REV_SKIP = 252
HOLD = 21
LIQ_WIN = 63
SMA_WIN = 200
MIN_BARS = REV_LB + REV_SKIP + 60
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
        df["ret"] = df["Adj Close"].pct_change()
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

    # equal-weight market level (for the 200d SMA regime filter)
    ret_mat = pd.DataFrame(index=cal)
    for tkr, df in frames.items():
        ret_mat[tkr] = df["ret"].reindex(cal)
    mkt_ret = ret_mat.mean(axis=1, skipna=True).fillna(0.0)
    mkt_level = (1.0 + mkt_ret).cumprod()
    mkt_sma = mkt_level.rolling(SMA_WIN).mean()

    recs = []
    for ri in range(first, last + 1, HOLD):
        t = cal[ri]
        tm0, tm1 = cal[ri - MOM_LB - MOM_SKIP], cal[ri - MOM_SKIP]
        tr0, tr1 = cal[ri - REV_LB - REV_SKIP], cal[ri - REV_SKIP]
        t_liq, t_fwd = cal[ri - LIQ_WIN], cal[ri + HOLD]
        lvl = float(mkt_level.iloc[ri]); sma = float(mkt_sma.iloc[ri])
        bear = (math.isfinite(sma) and lvl < sma)
        rows = []
        for tkr, df in frames.items():
            pm0 = df["Adj Close"].asof(tm0); pm1 = df["Adj Close"].asof(tm1)
            pr0 = df["Adj Close"].asof(tr0); pr1 = df["Adj Close"].asof(tr1)
            pn = df["Adj Close"].asof(t); pf = df["Adj Close"].asof(t_fwd)
            if any(pd.isna(x) or x <= 0 for x in (pm0, pm1, pr0, pr1, pn, pf)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            rows.append((tkr, (pm1/pm0)-1.0, (pr1/pr0)-1.0, (pf/pn)-1.0))
        if len(rows) < 30:
            continue
        toks = np.array([r[0] for r in rows])
        m12 = np.array([r[1] for r in rows])
        rev = np.array([r[2] for r in rows])
        fwd = np.array([r[3] for r in rows])
        sel12 = set(toks[np.argsort(m12)[-TOP_N:]].tolist())
        selrev = set(toks[np.argsort(rev)[:TOP_N]].tolist())
        recs.append({
            "year": t.year, "bear": bear,
            "sel12": sel12, "selrev": selrev,
            "fwd_by": {tk: f for tk, f in zip(toks, fwd)},
            "bench": float(np.mean(fwd)),
        })

    def _book_ret(r, key):
        sel = r[key]
        return float(np.mean([r["fwd_by"][tk] for tk in sel]))

    def _cost(prev, sel):
        turn = (len(prev.symmetric_difference(sel)) / 2.0 if prev else len(sel)) / max(len(sel), 1)
        return 2 * c * turn

    def build(split):
        if split == "train":
            rr = [r for r in recs if r["year"] < SPLIT_YEAR]
        elif split == "test":
            rr = [r for r in recs if r["year"] >= SPLIT_YEAR]
        else:
            rr = recs
        mom, rev, t9010, t8020, regime, bench = [], [], [], [], [], []
        pm = set(); pr = set()
        for r in rr:
            gm = _book_ret(r, "sel12"); gr = _book_ret(r, "selrev")
            cm = _cost(pm, r["sel12"]); cr = _cost(pr, r["selrev"])
            nm = gm - cm; nr = gr - cr
            mom.append(nm); rev.append(nr)
            t9010.append(0.9*nm + 0.1*nr)
            t8020.append(0.8*nm + 0.2*nr)
            if r["bear"]:
                regime.append(0.6*nm + 0.4*nr)
            else:
                regime.append(nm)
            bench.append(r["bench"] - 2*c*0.5)
            pm = r["sel12"]; pr = r["selrev"]
        bear_frac = round(float(np.mean([1.0 if r["bear"] else 0.0 for r in rr])), 3) if rr else None
        def exc(b):
            return _summ([a - x for a, x in zip(b, bench)])
        return {
            "n_rebalances": len(rr),
            "bear_fraction": bear_frac,
            "mom": _summ(mom), "rev": _summ(rev),
            "tilt_90_10": _summ(t9010), "tilt_80_20": _summ(t8020),
            "regime": _summ(regime),
            "excess_mom": exc(mom), "excess_tilt_90_10": exc(t9010),
            "excess_tilt_80_20": exc(t8020), "excess_regime": exc(regime),
        }

    return {
        "universe_symbols": len(frames),
        "total_rebalances": len(recs),
        "top_n": TOP_N, "split_year": SPLIT_YEAR,
        "full": build("full"), "train": build("train"), "test": build("test"),
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    p = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(p, "w"), indent=2)
    print("\nwrote", p)
