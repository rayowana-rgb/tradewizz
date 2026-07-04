"""Stage-3: long-only momentum RISK-CONTROL comparison.

The cash-gate crash guard hurt long-only momentum (it sat out recoveries). This
harness searches for a risk control that reduces drawdown / raises Sharpe
WITHOUT gutting the compounding, on the same top-decile 12-1 long-only book.

Overlays compared (all causal; use only info available at rebalance t):
  0. baseline            -- raw long-only top decile (reference).
  1. partial_voltarget   -- scale exposure in [0.5, 1.0] by target_vol/realized
                            vol of the strategy's own recent hold returns; never
                            zero (avoids the cash-gate mistake).
  2. per_hold_stop       -- cap each hold's loss at STOP (proxy for the app's
                            SL): realized hold return floored at -STOP.
  3. half_in_bear        -- when market < 200d MA, hold 50% (not 0%); else 100%.
  4. trend_scaled        -- continuous exposure = clip(1 + k*(mkt/ma - 1), 0.4, 1.2)
                            i.e. lean in above trend, ease off below, never cash.

Costs: 10 bps/side on turnover (name turnover + exposure changes). Benchmark =
equal-weight market. We report net-of-cost cum return, worst hold, Sharpe, and
excess-over-benchmark Sharpe for each overlay.
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
COST_BPS = 10.0
STOP = 0.15               # per-hold loss cap (monthly); app SL is intra-trade, this is a monthly proxy
TARGET_VOL_HOLD = 0.06    # target per-hold strategy vol for partial vol-target
TREND_K = 3.0


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


def _build_market(frames, cal) -> pd.DataFrame:
    rets = []
    for i in range(1, len(cal)):
        t, prev = cal[i], cal[i - 1]
        vals = []
        for df in frames.values():
            p1 = df["Adj Close"].asof(t); p0 = df["Adj Close"].asof(prev)
            if pd.notna(p1) and pd.notna(p0) and p0 > 0:
                vals.append(p1 / p0 - 1.0)
        rets.append(np.mean(vals) if vals else 0.0)
    s = pd.Series(rets, index=cal[1:])
    lvl = (1 + s).cumprod()
    ma = lvl.rolling(TREND_WIN).mean()
    return pd.DataFrame({"lvl": lvl, "ma": ma})


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
        "cum_return": round(lvl - 1.0, 3),
        "sharpe": round(m / sd * math.sqrt(12), 3) if sd > 0 else None,
    }


def run() -> dict:
    frames = _load_max_us()
    cal = _common_calendar(frames)
    mkt = _build_market(frames, cal)
    c = COST_BPS / 10000.0

    first = LOOKBACK + SKIP
    last = len(cal) - HOLD - 1

    # raw per-rebalance strategy return + context, then apply overlays post hoc
    rows = []  # (raw_top_ret, bench_ret, mkt_over_ma)
    prev_top: set = set()
    prev_bench: set = set()
    turnovers = []
    for ri in range(first, last + 1, HOLD):
        t = cal[ri]
        t0, t1 = cal[ri - LOOKBACK - SKIP], cal[ri - SKIP]
        t_liq, t_fwd = cal[ri - LIQ_WIN], cal[ri + HOLD]
        names, momen, fwd = [], [], []
        for tkr, df in frames.items():
            p0 = df["Adj Close"].asof(t0); p1 = df["Adj Close"].asof(t1)
            pn = df["Adj Close"].asof(t); pf = df["Adj Close"].asof(t_fwd)
            if any(pd.isna(x) or x <= 0 for x in (p0, p1, pn, pf)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            names.append(tkr); momen.append((p1 / p0) - 1.0); fwd.append((pf / pn) - 1.0)
        if len(names) < 40:
            continue
        momen = np.array(momen); fwd = np.array(fwd); names = np.array(names)
        order = np.argsort(momen)
        top = set(names[order[-max(1, len(names) // N_DECILES):]].tolist())
        top_idx = [i for i, nm in enumerate(names) if nm in top]
        raw_top = float(np.mean(fwd[top_idx]))
        bench_ret = float(np.mean(fwd))
        lvl_t = mkt["lvl"].asof(t); ma_t = mkt["ma"].asof(t)
        over_ma = float(lvl_t / ma_t) if (pd.notna(lvl_t) and pd.notna(ma_t) and ma_t) else 1.0
        # name turnover cost baseline
        chg = len(prev_top.symmetric_difference(top)) / 2.0 if prev_top else len(top)
        to = chg / max(len(top), 1)
        prev_top = top
        prev_bench = set(names.tolist())
        rows.append({"raw": raw_top, "bench": bench_ret, "over_ma": over_ma, "to": to})

    # benchmark net of its own name turnover ~ approximate small; charge 0.5*name to
    bench = [r["bench"] - 2 * c * 0.5 for r in rows]

    def overlay(kind):
        out = []
        prev_exp = 1.0
        recent = []  # recent applied strategy returns for vol estimate
        for r in rows:
            raw = r["raw"]
            exp = 1.0
            if kind == "baseline":
                exp = 1.0
            elif kind == "partial_voltarget":
                rv = float(np.std(recent[-6:])) if len(recent) >= 3 else None
                exp = min(1.0, max(0.5, TARGET_VOL_HOLD / rv)) if (rv and rv > 0) else 1.0
            elif kind == "half_in_bear":
                exp = 0.5 if r["over_ma"] < 1.0 else 1.0
            elif kind == "trend_scaled":
                exp = min(1.2, max(0.4, 1 + TREND_K * (r["over_ma"] - 1.0)))
            eff = raw * exp
            if kind == "per_hold_stop":
                eff = max(raw, -STOP)
                exp = 1.0
            # costs: name turnover + exposure change turnover
            exp_to = abs(exp - prev_exp)
            eff -= 2 * c * (r["to"] * exp + exp_to)
            out.append(eff)
            recent.append(raw)
            prev_exp = exp
        return out

    kinds = ["baseline", "partial_voltarget", "per_hold_stop", "half_in_bear", "trend_scaled"]
    net = {k: overlay(k) for k in kinds}
    excess = {k: [a - b for a, b in zip(net[k], bench)] for k in kinds}

    return {
        "universe_symbols": len(frames),
        "rebalances": len(rows),
        "cost_bps_per_side": COST_BPS,
        "params": {"stop": STOP, "target_vol_hold": TARGET_VOL_HOLD, "trend_k": TREND_K},
        "benchmark": _summ(bench),
        "net_of_cost": {k: _summ(net[k]) for k in kinds},
        "excess_over_benchmark": {k: _summ(excess[k]) for k in kinds},
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    p = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(p, "w"), indent=2)
    print("\nwrote", p)
