"""Stage-4 OUT-OF-SAMPLE test of 12-1 momentum + crash guard.

The strongest evidence chain so far:
  - 12-1 momentum: real edge over 2006-2026 (IC t 1.76) but crash-prone.
  - crash-guard: vol-target + bear/vol gate cut the tail and beat raw momentum.
BUT both were measured in-sample. This harness enforces a genuine
train/test split to check the edge and the guard are NOT overfit.

Protocol (no look-ahead, no test-set peeking for calibration):
  TRAIN = rebalances with year <= 2016.  TEST = year >= 2017.
  1. Compute the raw 12-1 long-short spread series over ALL rebalances (the
     signal itself has no free parameters, so this is fine).
  2. Report 12-1 IC / spread separately for TRAIN and TEST -> does the SIGNAL
     generalize?
  3. CALIBRATE the crash guard using TRAIN ONLY:
       - target_vol_per_hold := TRAIN std of the raw spread (so vol-target aims
         at the strategy's own historical vol).
       - vol tercile cutoff for the bear+vol gate := the 66.7th percentile of
         market realized vol computed on TRAIN dates only.
       - the 200d MA trend rule has no free parameter.
     Then APPLY those frozen parameters to the TEST rebalances only, and compare
     raw vs guarded on TEST -> does the GUARD generalize?
Everything uses information available at each rebalance date t.
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
N_DECILES = 10
ADV_FLOOR = 100_000.0
ZERO_VOL_MAX = 0.20
DOLLAR_FLOOR = 1_000.0
TREND_WIN = 200
MKT_VOL_WIN = 21
SPLIT_YEAR = 2017  # TEST = year >= SPLIT_YEAR


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


def _spearman(a, b) -> float:
    ra = pd.Series(a).rank().values
    rb = pd.Series(b).rank().values
    if np.std(ra) == 0 or np.std(rb) == 0:
        return float("nan")
    return float(np.corrcoef(ra, rb)[0, 1])


def _is_tradable(df, t_lo, t) -> bool:
    w = df.loc[(df.index > t_lo) & (df.index <= t)]
    if len(w) < LIQ_WIN * 0.6:
        return False
    adv = float(np.median(w["dv"]))
    zero_frac = float((w["dv"] < DOLLAR_FLOOR).mean())
    return (adv >= ADV_FLOOR) and (zero_frac <= ZERO_VOL_MAX)


def _build_market(frames, cal) -> pd.DataFrame:
    rets = []
    for i in range(1, len(cal)):
        t, prev = cal[i], cal[i - 1]
        vals = []
        for df in frames.values():
            p1 = df["Adj Close"].asof(t)
            p0 = df["Adj Close"].asof(prev)
            if pd.notna(p1) and pd.notna(p0) and p0 > 0:
                vals.append(p1 / p0 - 1.0)
        rets.append(np.mean(vals) if vals else 0.0)
    s = pd.Series(rets, index=cal[1:])
    lvl = (1 + s).cumprod()
    ma = lvl.rolling(TREND_WIN).mean()
    rvol = s.rolling(MKT_VOL_WIN).std() * math.sqrt(252)
    return pd.DataFrame({"lvl": lvl, "ma": ma, "rvol": rvol})


def _summ(series: List[float]) -> dict:
    s = [x for x in series if x is not None and math.isfinite(x)]
    if not s:
        return {"n": 0}
    m = float(np.mean(s)); sd = float(np.std(s, ddof=1)) if len(s) > 1 else 0.0
    return {
        "n": len(s),
        "mean_per_hold": round(m, 4),
        "worst": round(min(s), 4),
        "sum": round(sum(s), 4),
        "sharpe_annual_proxy": round(m / sd * math.sqrt(12), 3) if sd > 0 else None,
        "tstat": round(m / (sd / math.sqrt(len(s))), 3) if sd > 0 else None,
    }


def run() -> dict:
    frames = _load_max_us()
    cal = _common_calendar(frames)
    mkt = _build_market(frames, cal)

    first = LOOKBACK + SKIP
    last = len(cal) - HOLD - 1
    recs = []
    for ri in range(first, last + 1, HOLD):
        t = cal[ri]
        t0, t1 = cal[ri - LOOKBACK - SKIP], cal[ri - SKIP]
        t_liq, t_fwd = cal[ri - LIQ_WIN], cal[ri + HOLD]
        rows = []
        for df in frames.values():
            p0 = df["Adj Close"].asof(t0); p1 = df["Adj Close"].asof(t1)
            pn = df["Adj Close"].asof(t); pf = df["Adj Close"].asof(t_fwd)
            if any(pd.isna(x) or x <= 0 for x in (p0, p1, pn, pf)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            rows.append(((p1 / p0) - 1.0, (pf / pn) - 1.0))
        if len(rows) < 40:
            continue
        arr = np.array(rows)
        order = np.argsort(arr[:, 0])
        bkt = np.array_split(order, N_DECILES)
        dfwd = np.array([arr[b, 1].mean() for b in bkt])
        spread = float(dfwd[-1] - dfwd[0])
        ic = _spearman(arr[:, 0], arr[:, 1])
        lvl_t = mkt["lvl"].asof(t); ma_t = mkt["ma"].asof(t); rvol_t = mkt["rvol"].asof(t)
        bear = bool(pd.notna(lvl_t) and pd.notna(ma_t) and lvl_t < ma_t)
        recs.append({
            "year": t.year, "spread": spread, "ic": ic,
            "bear": bear, "rvol": float(rvol_t) if pd.notna(rvol_t) else None,
        })

    train = [r for r in recs if r["year"] < SPLIT_YEAR]
    test = [r for r in recs if r["year"] >= SPLIT_YEAR]

    # --- SIGNAL generalization ---
    tr_ic = [r["ic"] for r in train if r["ic"] is not None and math.isfinite(r["ic"])]
    te_ic = [r["ic"] for r in test if r["ic"] is not None and math.isfinite(r["ic"])]

    def _ic_stat(xs):
        if len(xs) < 2:
            return {"n": len(xs)}
        m = float(np.mean(xs)); sd = float(np.std(xs, ddof=1))
        return {"n": len(xs), "mean_ic": round(m, 4),
                "ic_tstat": round(m / (sd / math.sqrt(len(xs))), 3) if sd > 0 else None}

    # --- CALIBRATE guard on TRAIN ONLY ---
    tr_spreads = [r["spread"] for r in train]
    target_vol = float(np.std(tr_spreads, ddof=1))              # frozen from train
    tr_rvols = [r["rvol"] for r in train if r["rvol"] is not None]
    vol_cut = float(np.percentile(tr_rvols, 66.7)) if tr_rvols else None  # frozen

    def _apply(recset):
        raw, vt, gated = [], [], []
        prev = []  # trailing spreads for vol-target realized vol
        for r in recset:
            sp = r["spread"]
            raw.append(sp)
            rv = float(np.std(prev[-6:])) if len(prev) >= 3 else None
            scale = min(1.5, target_vol / rv) if (rv and rv > 0) else 1.0
            vt.append(sp * scale)
            highvol = (vol_cut is not None and r["rvol"] is not None and r["rvol"] >= vol_cut)
            gated.append(0.0 if (r["bear"] and highvol) else sp)
            prev.append(sp)
        return raw, vt, gated

    tr_raw, tr_vt, tr_gate = _apply(train)
    te_raw, te_vt, te_gate = _apply(test)

    return {
        "universe_symbols": len(frames),
        "split_year": SPLIT_YEAR,
        "train_rebalances": len(train),
        "test_rebalances": len(test),
        "calibrated_on_train": {
            "target_vol_per_hold": round(target_vol, 4),
            "market_vol_tercile_cut": round(vol_cut, 4) if vol_cut else None,
        },
        "signal_generalization": {
            "train_12_1": _ic_stat(tr_ic),
            "test_12_1": _ic_stat(te_ic),
        },
        "guard_generalization": {
            "TRAIN": {"raw": _summ(tr_raw), "vol_target": _summ(tr_vt), "bear_vol_gate": _summ(tr_gate)},
            "TEST": {"raw": _summ(te_raw), "vol_target": _summ(te_vt), "bear_vol_gate": _summ(te_gate)},
        },
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    p = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(p, "w"), indent=2)
    print("\nwrote", p)
