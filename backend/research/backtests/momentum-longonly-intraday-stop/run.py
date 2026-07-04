"""Stage-3: long-only momentum with REALISTIC intraday SL/TP (app mechanics).

Replaces the crude monthly -15% floor proxy with a true path-dependent stop:
each held name is entered at its price on rebalance day t, then on every day of
the 21-day hold we check the daily HIGH/LOW against a stop-loss and take-profit
level. If breached, the position exits that day at the level (or at the open if
the day GAPPED through it -- conservative, never better than open), and the
freed capital sits in cash for the rest of the hold.

This mirrors the TradeWizz app exactly: it buys ~10 names and manages each with
per-position SL/TP. User's live config is SL -1% / TP +3% (R:R 1:3); we also
test wider bands better matched to a monthly holding period.

Conservative conventions (never flatter than reality):
  - If BOTH stop and target are inside a single day's [low, high], assume the
    STOP fires first (worst case for us).
  - If the day OPENS beyond a level (gap), exit at the OPEN, not the level.
  - Costs: 10 bps/side, charged on entry and on each exit.

Compared vs: no-stop baseline (top-10 held full 21d) and the equal-weight
benchmark, all net of cost. Reports per SL/TP band.
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
# (stop_loss_pct, take_profit_pct) as positive fractions
BANDS: List[Tuple[float, float]] = [
    (0.01, 0.03),   # app live config: SL -1% / TP +3%
    (0.03, 0.09),   # wider, same 1:3
    (0.05, 0.15),   # wider still, 1:3
    (0.08, 0.24),   # loose
]


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
        # adjustment factor to convert raw OHLC to split/div-adjusted space
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


def _hold_return_with_stops(df, entry_t, cal, ri, sl, tp) -> float:
    """Path-dependent hold return for one name given SL/TP fractions.

    Entry at adjusted close on rebalance day. Walk the next HOLD trading days;
    on each, if the adjusted low <= stop_level OR adjusted high >= target_level,
    exit (stop assumed first if both). Gaps: exit at that day's open if the open
    is already beyond the level. If never triggered, exit at close of day HOLD.
    """
    entry = df["Adj Close"].asof(entry_t)
    if pd.isna(entry) or entry <= 0:
        return None
    stop_level = entry * (1 - sl)
    tgt_level = entry * (1 + tp)
    for k in range(1, HOLD + 1):
        d = cal[ri + k]
        row_idx = df.index.asof(d)
        if row_idx is None or pd.isna(row_idx) or row_idx not in df.index:
            continue
        o = df.at[row_idx, "adjOpen"]; hi = df.at[row_idx, "adjHigh"]; lo = df.at[row_idx, "adjLow"]
        if any(pd.isna(x) for x in (o, hi, lo)):
            continue
        # gap through stop at open
        if o <= stop_level:
            return o / entry - 1.0
        # gap through target at open
        if o >= tgt_level:
            return o / entry - 1.0
        hit_stop = lo <= stop_level
        hit_tgt = hi >= tgt_level
        if hit_stop:  # conservative: stop first if both
            return -sl
        if hit_tgt:
            return tp
    # exit at close of final hold day
    exit_p = df["Adj Close"].asof(cal[ri + HOLD])
    if pd.isna(exit_p) or exit_p <= 0:
        return None
    return exit_p / entry - 1.0


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
    c = COST_BPS / 10000.0
    first = LOOKBACK + SKIP
    last = len(cal) - HOLD - 1

    # For each rebalance store the selected top-10 tickers + plain fwd + bench
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
        recs.append({"ri": ri, "t": t, "sel": sel, "bench": float(np.mean(fwd))})

    bench = [r["bench"] - 2 * c * 0.5 for r in recs]

    baseline = []  # top-10 held full 21d, no stop
    for r in recs:
        vals = []
        for tkr in r["sel"]:
            df = frames[tkr]
            pn = df["Adj Close"].asof(r["t"]); pf = df["Adj Close"].asof(cal[r["ri"] + HOLD])
            if pd.notna(pn) and pd.notna(pf) and pn > 0:
                vals.append(pf / pn - 1.0)
        if vals:
            baseline.append(float(np.mean(vals)) - 2 * c * 1.0)

    band_out = {}
    for sl, tp in BANDS:
        series = []
        for r in recs:
            vals = []
            for tkr in r["sel"]:
                hr = _hold_return_with_stops(frames[tkr], r["t"], cal, r["ri"], sl, tp)
                if hr is not None:
                    vals.append(hr)
            if vals:
                # cost: entry (1 side) + exit (1 side) per name ~ 2 sides on the book
                series.append(float(np.mean(vals)) - 2 * c * 1.0)
        key = f"SL{int(sl*100)}_TP{int(tp*100)}"
        band_out[key] = {
            "net": _summ(series),
            "excess": _summ([a - b for a, b in zip(series, bench)]),
        }

    return {
        "universe_symbols": len(frames),
        "rebalances": len(recs),
        "top_n": TOP_N,
        "cost_bps_per_side": COST_BPS,
        "note": "intraday path-dependent SL/TP using daily adj OHLC; stop-first on tie; gap exits at open",
        "benchmark": _summ(bench),
        "baseline_no_stop": _summ(baseline),
        "bands": band_out,
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    p = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(p, "w"), indent=2)
    print("\nwrote", p)
