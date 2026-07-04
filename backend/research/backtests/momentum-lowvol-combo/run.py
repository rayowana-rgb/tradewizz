"""Stage-3: does combining momentum with an ORTHOGONAL low-vol book raise
portfolio Sharpe via decorrelation?

Two long-only books, both top-10 / monthly / no-tight-stop / net 10bps/side on
the same tradable US universe:
  - MOMENTUM: top-10 by 12-1 (the validated production spec)
  - LOW-VOL : top-10 by LOWEST trailing 63d daily-return volatility (classic
              low-volatility anomaly -- expected to be roughly orthogonal to
              momentum)

We report, net of cost, for each book and a 50/50 BLEND (rebalanced monthly):
  - stand-alone stats + excess over the equal-weight benchmark
  - the CORRELATION between the two books' per-rebalance returns (the key: if
    low, the blend gets a decorrelation Sharpe lift)
  - the blend's excess Sharpe vs the better single book

Also split TRAIN(<2017)/TEST(>=2017) so we don't overclaim a blend benefit that
only exists in-sample. No fabricated numbers -- if a book has no edge we say so.
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
VOL_WIN = 63
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
    first = LOOKBACK + SKIP
    last = len(cal) - HOLD - 1

    recs = []
    for ri in range(first, last + 1, HOLD):
        t = cal[ri]
        t0, t1 = cal[ri - LOOKBACK - SKIP], cal[ri - SKIP]
        t_liq, t_fwd, t_vol = cal[ri - LIQ_WIN], cal[ri + HOLD], cal[ri - VOL_WIN]
        rows = []
        allfwd = []
        for tkr, df in frames.items():
            p0 = df["Adj Close"].asof(t0); p1 = df["Adj Close"].asof(t1)
            pn = df["Adj Close"].asof(t); pf = df["Adj Close"].asof(t_fwd)
            if any(pd.isna(x) or x <= 0 for x in (p0, p1, pn, pf)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            vw = df.loc[(df.index > t_vol) & (df.index <= t), "ret"].dropna()
            if len(vw) < VOL_WIN * 0.6:
                continue
            vol = float(np.std(vw))
            if not math.isfinite(vol) or vol <= 0:
                continue
            mom = (p1 / p0) - 1.0
            fwd = (pf / pn) - 1.0
            rows.append((tkr, mom, vol, fwd))
            allfwd.append(fwd)
        if len(rows) < 40:
            continue
        toks = np.array([r[0] for r in rows])
        mom = np.array([r[1] for r in rows])
        vol = np.array([r[2] for r in rows])
        fwd = np.array([r[3] for r in rows])
        mom_sel = set(toks[np.argsort(mom)[-TOP_N:]].tolist())
        lv_sel = set(toks[np.argsort(vol)[:TOP_N]].tolist())  # lowest vol
        fwd_by = {tk: f for tk, f in zip(toks, fwd)}
        recs.append({
            "ri": ri, "year": t.year,
            "mom_sel": mom_sel, "lv_sel": lv_sel, "fwd_by": fwd_by,
            "bench": float(np.mean(fwd)),
        })

    def _book_series(rr, key):
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
        mom = _book_series(rr, "mom_sel")
        lv = _book_series(rr, "lv_sel")
        bench = [r["bench"] - 2 * c * 0.5 for r in rr]
        blend = [0.5 * a + 0.5 * b for a, b in zip(mom, lv)]
        corr = None
        if len(mom) > 2:
            cc = np.corrcoef(mom, lv)[0, 1]
            corr = round(float(cc), 3) if math.isfinite(cc) else None
        return {
            "n_rebalances": len(rr),
            "corr_mom_lv": corr,
            "momentum": _summ(mom),
            "low_vol": _summ(lv),
            "blend_50_50": _summ(blend),
            "excess_momentum": _summ([a - b for a, b in zip(mom, bench)]),
            "excess_low_vol": _summ([a - b for a, b in zip(lv, bench)]),
            "excess_blend": _summ([a - b for a, b in zip(blend, bench)]),
        }

    return {
        "universe_symbols": len(frames),
        "total_rebalances": len(recs),
        "top_n": TOP_N,
        "vol_win": VOL_WIN,
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
