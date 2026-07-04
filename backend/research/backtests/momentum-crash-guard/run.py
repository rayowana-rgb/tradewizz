"""Stage-3 (multi-year) test of a momentum CRASH GUARD.

Context: the multi-year 12-1 momentum re-test showed a real edge (IC t 1.76 over
2006-2026) BUT with textbook momentum crashes (2009 IC -0.15/spread -7%,
2023 -8%). Literature (Daniel-Moskowitz 2016; Barroso-Santa-Clara 2015) says
these crashes are PREDICTABLE: they cluster after bear markets, in high-
volatility "panic-then-rebound" states, when prior losers rebound hardest.

Two guard designs tested here on the SAME 12-1 momentum long-short spread:
  (1) VOL-TARGET (Barroso-Santa-Clara): scale the momentum bet by
      target_vol / realized_vol_of_the_strategy. Caps leverage in turbulent
      months; does not need to *predict* a crash, just react to strategy vol.
  (2) BEAR+VOL GATE (Daniel-Moskowitz flavor): turn the momentum bet OFF (or
      halve it) when the market is BELOW its 200d MA *and* market realized vol
      is in its top tercile -- the state where crashes concentrate.

We measure, per design, on the realized per-rebalance 12-1 spread series:
  mean/hold, annualized-ish Sharpe proxy, WORST rebalance (tail), sum,
  and the same broken out for crash years (2009, 2020, 2022, 2023).
Goal: does the guard cut the left tail without killing the mean?
No look-ahead: vol/trend use only info available at rebalance date t.
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

TREND_WIN = 200          # market MA window
MKT_VOL_WIN = 21         # market realized vol window
TARGET_VOL_PER_HOLD = 0.02   # ~2% per 21d target for the strategy spread


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


def _build_market_proxy(frames, cal) -> pd.DataFrame:
    """Equal-weight daily return of tradable US names -> market level, MA, vol."""
    rets = []
    for d_i in range(1, len(cal)):
        t = cal[d_i]
        prev = cal[d_i - 1]
        vals = []
        for df in frames.values():
            p1 = df["Adj Close"].asof(t)
            p0 = df["Adj Close"].asof(prev)
            if pd.notna(p1) and pd.notna(p0) and p0 > 0:
                vals.append(p1 / p0 - 1.0)
        rets.append(np.mean(vals) if vals else 0.0)
    idx = cal[1:]
    s = pd.Series(rets, index=idx)
    lvl = (1 + s).cumprod()
    ma = lvl.rolling(TREND_WIN).mean()
    rvol = s.rolling(MKT_VOL_WIN).std() * math.sqrt(252)
    out = pd.DataFrame({"ret": s, "lvl": lvl, "ma": ma, "rvol": rvol})
    out["rvol_ptile"] = out["rvol"].expanding().apply(
        lambda x: (x.rank(pct=True).iloc[-1]) if len(x) else np.nan, raw=False)
    return out


def run() -> dict:
    frames = _load_max_us()
    cal = _common_calendar(frames)
    mkt = _build_market_proxy(frames, cal)

    first = LOOKBACK + SKIP
    last = len(cal) - HOLD - 1
    # per-rebalance realized 12-1 long-short spread + market state at t
    recs = []  # (date, spread, strat_vol_est, bear_gate_on)
    spread_hist: List[float] = []
    for ri in range(first, last + 1, HOLD):
        t = cal[ri]
        t0 = cal[ri - LOOKBACK - SKIP]
        t1 = cal[ri - SKIP]
        t_liq = cal[ri - LIQ_WIN]
        t_fwd = cal[ri + HOLD]
        rows = []
        for df in frames.values():
            p0 = df["Adj Close"].asof(t0)
            p1 = df["Adj Close"].asof(t1)
            pn = df["Adj Close"].asof(t)
            pf = df["Adj Close"].asof(t_fwd)
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

        # strategy vol estimate from trailing realized spreads (no look-ahead)
        strat_vol = float(np.std(spread_hist[-6:])) if len(spread_hist) >= 3 else None
        # bear+vol gate state at t (info known at t)
        lvl_t = mkt["lvl"].asof(t)
        ma_t = mkt["ma"].asof(t)
        vptile_t = mkt["rvol_ptile"].asof(t)
        bear = (pd.notna(lvl_t) and pd.notna(ma_t) and lvl_t < ma_t)
        highvol = (pd.notna(vptile_t) and vptile_t >= 0.667)
        gate_off = bool(bear and highvol)

        recs.append({
            "date": str(t.date()), "year": t.year, "spread": spread,
            "strat_vol": strat_vol, "gate_off": gate_off,
        })
        spread_hist.append(spread)

    def _summ(series: List[float]) -> dict:
        s = [x for x in series if x is not None and math.isfinite(x)]
        if not s:
            return {"n": 0}
        m = float(np.mean(s)); sd = float(np.std(s, ddof=1)) if len(s) > 1 else 0.0
        sharpe = (m / sd * math.sqrt(12)) if sd > 0 else None  # ~12 holds/yr
        return {
            "n": len(s),
            "mean_per_hold": round(m, 4),
            "worst": round(min(s), 4),
            "best": round(max(s), 4),
            "sum": round(sum(s), 4),
            "sharpe_annual_proxy": round(sharpe, 3) if sharpe is not None else None,
            "neg_holds": int(sum(1 for x in s if x < 0)),
        }

    raw = [r["spread"] for r in recs]

    # (1) vol-target overlay
    vt = []
    for r in recs:
        if r["strat_vol"] and r["strat_vol"] > 0:
            scale = min(1.5, TARGET_VOL_PER_HOLD / r["strat_vol"])
        else:
            scale = 1.0
        vt.append(r["spread"] * scale)

    # (2) bear+vol gate (turn OFF -> 0 when gate_off)
    gated = [0.0 if r["gate_off"] else r["spread"] for r in recs]
    # (2b) gate HALVE
    gated_half = [0.5 * r["spread"] if r["gate_off"] else r["spread"] for r in recs]

    crash_years = {2008, 2009, 2020, 2022, 2023}
    def _crash(series):
        return [s for s, r in zip(series, recs) if r["year"] in crash_years]

    out = {
        "universe_symbols": len(frames),
        "rebalances": len(recs),
        "data_window": f"{recs[0]['date']} .. {recs[-1]['date']}" if recs else None,
        "gate_off_fraction": round(sum(1 for r in recs if r["gate_off"]) / len(recs), 3) if recs else None,
        "designs": {
            "raw_momentum": _summ(raw),
            "vol_target": _summ(vt),
            "bear_vol_gate_off": _summ(gated),
            "bear_vol_gate_half": _summ(gated_half),
        },
        "crash_years_only": {
            "raw_momentum": _summ(_crash(raw)),
            "vol_target": _summ(_crash(vt)),
            "bear_vol_gate_off": _summ(_crash(gated)),
            "bear_vol_gate_half": _summ(_crash(gated_half)),
        },
    }
    return out


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    p = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(p, "w"), indent=2)
    print("\nwrote", p)
