"""Stage-3 (multi-year) re-test of cross-sectional momentum.

The FIRST atom rejected momentum partly because our ~1y cache could not even
form the classic 12-1 signal (needs ~278 trading days; we had ~251 common).
After the multi-year backfill we now have long history for the liquid names, so
we can finally test 12-1 properly AND across multiple regimes (COVID-2020 crash,
2022 bear, etc.).

Universe: the backfilled `period=max` US names (~343 liquid names). This is a
SMALLER cross-section than the 1y universe (~10k), so per-rebalance noise is
higher; we compensate with MANY rebalances across ~10 years and report the
distribution, not a single number.

Signal (classic momentum, no look-ahead):
  12-1: cumulative return over t-252..t-21 (skip most recent month).
   6-1: t-126..t-21 ;  3-1: t-63..t-21.
Forward: t..t+21 (1-month hold).
Liquidity gate: median 63d dollar-volume >= $100k, tradable only.

Reports per variant: mean IC (Spearman), IC t-stat across rebalances,
mean top-minus-bottom decile spread per hold, spread hit-rate, and a
per-CALENDAR-YEAR breakdown so regime dependence is visible.
"""
from __future__ import annotations

import glob
import json
import math
import os
from collections import defaultdict
from typing import Dict, List, Tuple

import numpy as np
import pandas as pd

CACHE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", ".cache", "ohlcv")
)

SKIP = 21
HOLD = 21
LIQ_WIN = 63
MIN_BARS = 300
N_DECILES = 10
ADV_FLOOR = 100_000.0
ZERO_VOL_MAX = 0.20
DOLLAR_FLOOR = 1_000.0
VARIANTS: List[Tuple[int, str]] = [(252, "12-1"), (126, "6-1"), (63, "3-1")]


def _load_max_us() -> Dict[str, pd.DataFrame]:
    out: Dict[str, pd.DataFrame] = {}
    for meta_path in glob.glob(os.path.join(CACHE, "*.meta.json")):
        try:
            meta = json.load(open(meta_path))
        except Exception:
            continue
        if (meta.get("market") != "US" or meta.get("interval") != "1d"
                or meta.get("period") != "max"):
            continue
        csv = meta_path.replace(".meta.json", ".csv")
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


def _common_calendar(frames: Dict[str, pd.DataFrame]) -> pd.DatetimeIndex:
    counts: Dict[pd.Timestamp, int] = defaultdict(int)
    for df in frames.values():
        for d in df.index:
            counts[d] += 1
    n = len(frames)
    return pd.DatetimeIndex(sorted(d for d, c in counts.items() if c >= 0.6 * n))


def _spearman(a: np.ndarray, b: np.ndarray) -> float:
    ra = pd.Series(a).rank().values
    rb = pd.Series(b).rank().values
    if np.std(ra) == 0 or np.std(rb) == 0:
        return float("nan")
    return float(np.corrcoef(ra, rb)[0, 1])


def _is_tradable(df: pd.DataFrame, t_lo, t) -> bool:
    w = df.loc[(df.index > t_lo) & (df.index <= t)]
    if len(w) < LIQ_WIN * 0.6:
        return False
    adv = float(np.median(w["dv"]))
    zero_frac = float((w["dv"] < DOLLAR_FLOOR).mean())
    return (adv >= ADV_FLOOR) and (zero_frac <= ZERO_VOL_MAX)


def run_variant(frames, cal, lookback: int, label: str) -> dict:
    first = lookback + SKIP
    last = len(cal) - HOLD - 1
    step = HOLD
    ics: List[float] = []
    tmbs: List[float] = []
    by_year: Dict[int, List[float]] = defaultdict(list)
    by_year_ic: Dict[int, List[float]] = defaultdict(list)

    for ri in range(first, last + 1, step):
        t = cal[ri]
        t_sig0 = cal[ri - lookback - SKIP]
        t_sig1 = cal[ri - SKIP]
        t_liq = cal[ri - LIQ_WIN]
        t_fwd = cal[ri + HOLD]
        recs = []
        for df in frames.values():
            try:
                p0 = df["Adj Close"].asof(t_sig0)
                p1 = df["Adj Close"].asof(t_sig1)
                pn = df["Adj Close"].asof(t)
                pf = df["Adj Close"].asof(t_fwd)
            except Exception:
                continue
            if any(pd.isna(x) or x <= 0 for x in (p0, p1, pn, pf)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            sig = (p1 / p0) - 1.0   # momentum: winners rank high
            fwd = (pf / pn) - 1.0
            if math.isfinite(sig) and math.isfinite(fwd):
                recs.append((sig, fwd))
        if len(recs) < 40:
            continue
        arr = np.array(recs)
        order = np.argsort(arr[:, 0])
        bkt = np.array_split(order, N_DECILES)
        dfwd = np.array([arr[b, 1].mean() for b in bkt])
        tmb = float(dfwd[-1] - dfwd[0])
        ic = _spearman(arr[:, 0], arr[:, 1])
        if math.isfinite(ic):
            ics.append(ic)
            by_year_ic[t.year].append(ic)
        tmbs.append(tmb)
        by_year[t.year].append(tmb)

    def _t(xs):
        xs = [x for x in xs if math.isfinite(x)]
        if len(xs) < 2:
            return None
        m = float(np.mean(xs)); s = float(np.std(xs, ddof=1))
        return round(m / (s / math.sqrt(len(xs))), 3) if s > 0 else None

    years = sorted(set(list(by_year.keys()) + list(by_year_ic.keys())))
    per_year = {}
    for y in years:
        tv = by_year.get(y, [])
        iv = [x for x in by_year_ic.get(y, []) if math.isfinite(x)]
        per_year[str(y)] = {
            "rebalances": len(tv),
            "mean_tmb": round(float(np.mean(tv)), 4) if tv else None,
            "mean_ic": round(float(np.mean(iv)), 4) if iv else None,
        }

    ic_fin = [x for x in ics if math.isfinite(x)]
    return {
        "label": label,
        "rebalances": len(tmbs),
        "mean_ic": round(float(np.mean(ic_fin)), 4) if ic_fin else None,
        "ic_tstat": _t(ics),
        "mean_top_minus_bottom_per_hold": round(float(np.mean(tmbs)), 4) if tmbs else None,
        "tmb_tstat": _t(tmbs),
        "spread_hit_rate": round(float(np.mean([1 if x > 0 else 0 for x in tmbs])), 4) if tmbs else None,
        "per_year": per_year,
    }


def run() -> dict:
    frames = _load_max_us()
    cal = _common_calendar(frames)
    out = {
        "universe_symbols": len(frames),
        "common_calendar_days": len(cal),
        "data_window": f"{cal[0].date()} .. {cal[-1].date()}" if len(cal) else None,
        "note": ("Liquid backfilled universe (~343 names) -> smaller cross-section "
                 "than 1y run; many rebalances across ~10y (incl. 2020 COVID crash, "
                 "2022 bear) compensate. IC t-stat across rebalances is the key stat."),
        "variants": {},
    }
    for lb, label in VARIANTS:
        out["variants"][label] = run_variant(frames, cal, lb, label)
    return out


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    p = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(p, "w"), indent=2)
    print("\nwrote", p)
