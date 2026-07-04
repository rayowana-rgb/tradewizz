"""Stage-3: RESIDUAL momentum -- an alpha-bearing partner designed to be MORE
orthogonal to raw 12-1 than another price-momentum horizon.

Motivation: raw 12-1 momentum is partly driven by market BETA (fast risers are
often just high-beta names in a bull tape). Residual momentum regresses each
name's daily returns on the equal-weight market return over the lookback window
and ranks by the mean RESIDUAL (the part NOT explained by the market). By
construction this strips the common beta component, so it should be far less
correlated with raw 12-1 than 6-1 was (corr 0.87) -- giving a BIGGER
decorrelation lift IF it also carries alpha.

Two long-only books, top-10 / monthly / no-tight-stop / net 10bps/side:
  - MOM_12_1   : raw 12-1 (252d return skip 21d) -- validated production signal
  - RESID_MOM  : rank by mean daily residual over the same 252d/skip-21d window
                 from an OLS of stock daily ret on equal-weight market daily ret

Reports TRAIN(<2017)/TEST(>=2017)/FULL, net cost:
  - each book stand-alone + excess over benchmark
  - correlation between the two books' per-rebalance returns  (key: LOW?)
  - a 50/50 blend + excess

CRITICAL TESTS:
  (1) does RESID_MOM carry alpha (excess-t > 0, ideally >~2)?
  (2) is corr(12-1, resid) MUCH lower than the 0.87 we saw for 6-1?
  (3) does the blend beat the multi-horizon blend's excess-t (3.18 FULL)?
No fabricated numbers -- if resid has no alpha, we say so.
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
SPLIT_YEAR = 2017
MIN_OVERLAP = int(LOOKBACK * 0.7)  # min aligned days for the regression


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
    cal_pos = {d: i for i, d in enumerate(cal)}
    c = COST_BPS / 10000.0
    first = LOOKBACK + SKIP
    last = len(cal) - HOLD - 1

    # Precompute equal-weight market daily return on the common calendar.
    ret_mat = pd.DataFrame(index=cal)
    for tkr, df in frames.items():
        ret_mat[tkr] = df["ret"].reindex(cal)
    mkt = ret_mat.mean(axis=1, skipna=True)  # equal-weight market daily return

    recs = []
    for ri in range(first, last + 1, HOLD):
        t = cal[ri]
        w0, w1 = ri - LOOKBACK - SKIP, ri - SKIP  # regression window [w0, w1)
        t_liq, t_fwd = cal[ri - LIQ_WIN], cal[ri + HOLD]
        mkt_win = mkt.iloc[w0:w1]
        mvar = float(np.nanvar(mkt_win.values))
        if not math.isfinite(mvar) or mvar <= 0:
            continue
        mmean = float(np.nanmean(mkt_win.values))
        rows = []
        for tkr, df in frames.items():
            p0 = df["Adj Close"].asof(cal[w0]); p1 = df["Adj Close"].asof(cal[w1])
            pn = df["Adj Close"].asof(t); pf = df["Adj Close"].asof(t_fwd)
            if any(pd.isna(x) or x <= 0 for x in (p0, p1, pn, pf)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            r = ret_mat[tkr].iloc[w0:w1]
            mask = r.notna() & mkt_win.notna()
            if int(mask.sum()) < MIN_OVERLAP:
                continue
            rv = r[mask].values; mv = mkt_win[mask].values
            cov = float(np.mean((rv - rv.mean()) * (mv - mv.mean())))
            beta = cov / float(np.var(mv)) if np.var(mv) > 0 else 0.0
            alpha = float(rv.mean()) - beta * float(mv.mean())
            resid_sum = alpha * len(rv)  # cumulative unexplained drift proxy
            mom12 = (p1 / p0) - 1.0
            fwd = (pf / pn) - 1.0
            rows.append((tkr, mom12, resid_sum, fwd))
        if len(rows) < 40:
            continue
        toks = np.array([r[0] for r in rows])
        m12 = np.array([r[1] for r in rows])
        resid = np.array([r[2] for r in rows])
        fwd = np.array([r[3] for r in rows])
        sel12 = set(toks[np.argsort(m12)[-TOP_N:]].tolist())
        selr = set(toks[np.argsort(resid)[-TOP_N:]].tolist())
        fwd_by = {tk: f for tk, f in zip(toks, fwd)}
        recs.append({
            "ri": ri, "year": t.year,
            "sel12": sel12, "selr": selr, "fwd_by": fwd_by,
            "bench": float(np.mean(fwd)),
            "overlap": len(sel12 & selr),
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
        br = _book(rr, "selr")
        bench = [r["bench"] - 2 * c * 0.5 for r in rr]
        blend = [0.5 * a + 0.5 * b for a, b in zip(b12, br)]
        corr = None
        if len(b12) > 2:
            cc = np.corrcoef(b12, br)[0, 1]
            corr = round(float(cc), 3) if math.isfinite(cc) else None
        avg_overlap = round(float(np.mean([r["overlap"] for r in rr])), 2) if rr else None
        return {
            "n_rebalances": len(rr),
            "corr_12_resid": corr,
            "avg_name_overlap_of_10": avg_overlap,
            "mom_12_1": _summ(b12),
            "resid_mom": _summ(br),
            "blend_50_50": _summ(blend),
            "excess_12_1": _summ([a - b for a, b in zip(b12, bench)]),
            "excess_resid": _summ([a - b for a, b in zip(br, bench)]),
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
