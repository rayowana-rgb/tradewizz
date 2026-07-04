"""Stage-3 LONG-ONLY, cost-aware test of 12-1 momentum + crash guard.

Motivation: every prior momentum backtest measured a LONG-SHORT decile spread.
The TradeWizz app trades LONG-ONLY (buy ~10 US names, no shorting). So the
production-relevant question is different: does buying the top-momentum decile,
long-only, net of trading costs, beat simply holding the market -- and does the
crash guard help in that realistic setting?

Design (no look-ahead):
  - Universe: backfilled period=max liquid US names (tradability gate at t).
  - Benchmark: equal-weight ALL tradable names each hold (a broad "market").
  - Strategy: equal-weight the TOP momentum decile (12-1 signal). Long only.
  - Costs: turnover-based. Each rebalance, cost = turnover * COST_BPS per side,
    where turnover = fraction of the book that changed vs the previous hold.
    Benchmark also pays cost on ITS (small) turnover for a fair comparison.
  - Crash guard (bear+vol gate, the OOS-validated design): when market < 200d MA
    AND market realized vol in top tercile -> strategy goes to CASH (ret 0) for
    that hold. Cash move itself incurs one-sided turnover cost.
  Report strategy vs benchmark vs guarded-strategy: mean excess/hold, cumulative,
  Sharpe proxy, worst hold, and net-of-cost cumulative.
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
COST_BPS = 10.0          # per side, in basis points (0.10%) -- liquid equity + slippage
VOL_TERCILE = 0.667


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
    rvol = s.rolling(MKT_VOL_WIN).std() * math.sqrt(252)
    rvol_ptile = rvol.expanding().apply(
        lambda x: x.rank(pct=True).iloc[-1] if len(x) else np.nan, raw=False)
    return pd.DataFrame({"lvl": lvl, "ma": ma, "rvol_ptile": rvol_ptile})


def _turnover(prev_set, new_set) -> float:
    if not prev_set and not new_set:
        return 0.0
    if not prev_set:
        return 1.0
    # fraction of equal-weight book that changed (one-sided)
    changed = len(prev_set.symmetric_difference(new_set)) / 2.0
    denom = max(len(prev_set), len(new_set), 1)
    return changed / denom


def _summ(series: List[float]) -> dict:
    s = [x for x in series if x is not None and math.isfinite(x)]
    if not s:
        return {"n": 0}
    m = float(np.mean(s)); sd = float(np.std(s, ddof=1)) if len(s) > 1 else 0.0
    lvl = 1.0
    for x in s:
        lvl *= (1 + x)
    return {
        "n": len(s),
        "mean_per_hold": round(m, 5),
        "worst": round(min(s), 4),
        "cum_return": round(lvl - 1.0, 4),
        "sharpe_annual_proxy": round(m / sd * math.sqrt(12), 3) if sd > 0 else None,
    }


def run() -> dict:
    frames = _load_max_us()
    cal = _common_calendar(frames)
    mkt = _build_market(frames, cal)
    c = COST_BPS / 10000.0

    first = LOOKBACK + SKIP
    last = len(cal) - HOLD - 1

    bench, strat, strat_g = [], [], []
    prev_strat: set = set()
    prev_g: set = set()
    prev_bench: set = set()
    n_gate_off = 0
    n_recs = 0
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
        n_recs += 1
        momen = np.array(momen); fwd = np.array(fwd); names = np.array(names)
        order = np.argsort(momen)
        top = set(names[order[-max(1, len(names) // N_DECILES):]].tolist())

        bench_ret = float(np.mean(fwd))
        top_idx = [i for i, nm in enumerate(names) if nm in top]
        strat_ret = float(np.mean(fwd[top_idx]))

        # costs (turnover-based, both sides)
        to_b = _turnover(prev_bench, set(names.tolist()))
        to_s = _turnover(prev_strat, top)
        bench.append(bench_ret - 2 * c * to_b)
        strat.append(strat_ret - 2 * c * to_s)
        prev_bench = set(names.tolist()); prev_strat = top

        # crash guard
        lvl_t = mkt["lvl"].asof(t); ma_t = mkt["ma"].asof(t); vpt = mkt["rvol_ptile"].asof(t)
        bear = bool(pd.notna(lvl_t) and pd.notna(ma_t) and lvl_t < ma_t)
        highvol = bool(pd.notna(vpt) and vpt >= VOL_TERCILE)
        if bear and highvol:
            n_gate_off += 1
            to_g = _turnover(prev_g, set())  # liquidate to cash
            strat_g.append(0.0 - 2 * c * to_g)
            prev_g = set()
        else:
            to_g = _turnover(prev_g, top)
            strat_g.append(strat_ret - 2 * c * to_g)
            prev_g = top

    excess = [s - b for s, b in zip(strat, bench)]
    excess_g = [g - b for g, b in zip(strat_g, bench)]

    return {
        "universe_symbols": len(frames),
        "rebalances": n_recs,
        "cost_bps_per_side": COST_BPS,
        "gate_off_fraction": round(n_gate_off / n_recs, 3) if n_recs else None,
        "net_of_cost": {
            "benchmark_equal_weight": _summ(bench),
            "momentum_top_decile": _summ(strat),
            "momentum_top_decile_guarded": _summ(strat_g),
        },
        "excess_over_benchmark": {
            "momentum_top_decile": _summ(excess),
            "momentum_top_decile_guarded": _summ(excess_g),
        },
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    p = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(p, "w"), indent=2)
    print("\nwrote", p)
