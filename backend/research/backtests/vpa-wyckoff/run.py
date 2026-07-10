"""Stage-3 head-to-head: VPA+Wyckoff (mechanical proxy) vs 12-1 momentum.

Both signals are evaluated in the EXACT SAME long-only, cost-aware, monthly-hold,
equal-weight-top-decile framework as `momentum-longonly`, on the SAME max-history
liquid US cache and the SAME rebalance calendar. The ONLY thing that varies
between the two strategies is the ranking signal, so the comparison is fair.

No look-ahead: every signal at rebalance time t uses only data with index <= t;
forward returns use the NEXT hold window (t -> t+HOLD).

Signals
-------
momentum : 12-1 total return = AdjClose[t-SKIP] / AdjClose[t-LOOKBACK-SKIP] - 1.

vpa      : VPA+Wyckoff accumulation score, sum of standardized components on the
           trailing window (all computed on data <= t):
             1. effort_vs_result: (avg vol on up-days - avg vol on down-days)/avg vol, 60d
             2. close_strength  : mean (Close-Low)/(High-Low), 20d
             3. vw_trend        : Close vs 20d & 50d volume-weighted avg price (proxy VWAP)
             4. spring bonus    : recent (<=10d) 20d-low that closed back up on high volume
             5. upthrust penalty: recent (<=10d) 20d-high that closed weak on high volume
           Components are cross-sectionally z-scored each rebalance, then summed.

Both strategies: long-only, equal-weight the TOP decile, rebalance monthly,
turnover-based cost of COST_BPS per side. Benchmark = equal-weight ALL tradable
names (pays cost on its own small turnover too).
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
COST_BPS = 10.0

# VPA windows
EVR_WIN = 60
CS_WIN = 20
VW_SHORT = 20
VW_LONG = 50
EXTREME_WIN = 20
RECENT_WIN = 10


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
        need = {"Date", "Adj Close", "Close", "Volume", "High", "Low"}
        if not need.issubset(df.columns) or len(df) < MIN_BARS:
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


def _turnover(prev_set, new_set) -> float:
    if not prev_set and not new_set:
        return 0.0
    if not prev_set:
        return 1.0
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


def _excess_t(excess: List[float]):
    s = [x for x in excess if x is not None and math.isfinite(x)]
    if len(s) < 2:
        return None
    m = float(np.mean(s)); sd = float(np.std(s, ddof=1))
    return round(m / (sd / math.sqrt(len(s))), 3) if sd > 0 else None


def _vpa_score(df: pd.DataFrame, t) -> float | None:
    """VPA+Wyckoff accumulation score using only data with index <= t."""
    w = df.loc[df.index <= t]
    if len(w) < EVR_WIN + 5:
        return None
    close = w["Close"]; high = w["High"]; low = w["Low"]; vol = w["Volume"].clip(lower=0)
    adjc = w["Adj Close"]

    # 1) effort vs result (60d): up-day vol vs down-day vol
    r = adjc.pct_change()
    win = slice(-EVR_WIN, None)
    rr = r.iloc[win]; vv = vol.iloc[win]
    up = vv[rr > 0]; dn = vv[rr < 0]
    avgv = float(vv.mean()) if float(vv.mean()) > 0 else np.nan
    if not math.isfinite(avgv):
        return None
    evr = (float(up.mean() if len(up) else 0.0) - float(dn.mean() if len(dn) else 0.0)) / avgv

    # 2) close strength (20d): position of close in daily range
    rng = (high - low).replace(0, np.nan)
    cs = ((close - low) / rng).iloc[-CS_WIN:]
    close_strength = float(cs.mean()) if cs.notna().any() else 0.5

    # 3) volume-weighted trend: price vs proxy VWAP (20d, 50d)
    def _vwap(n):
        c = close.iloc[-n:]; v = vol.iloc[-n:]
        vs = float(v.sum())
        return float((c * v).sum() / vs) if vs > 0 else float(c.mean())
    vw20 = _vwap(VW_SHORT); vw50 = _vwap(VW_LONG)
    px = float(close.iloc[-1])
    vw_trend = ((px / vw20) - 1.0 if vw20 > 0 else 0.0) + ((px / vw50) - 1.0 if vw50 > 0 else 0.0)

    # 4) spring bonus: recent window undercut the prior 20d low but the latest
    #    close recovered back above it on above-average volume (classic shakeout)
    spring = 0.0
    recent = w.iloc[-RECENT_WIN:]
    prior_low = float(low.iloc[-(EXTREME_WIN + RECENT_WIN):-RECENT_WIN].min()) if len(low) >= EXTREME_WIN + RECENT_WIN else float(low.min())
    rlow = float(recent["Low"].min())
    rclose = float(recent["Close"].iloc[-1])
    rvol_mean = float(recent["Volume"].mean())
    if rlow < prior_low and rclose > prior_low and rvol_mean > avgv:
        spring = 1.0

    # 5) upthrust penalty: recent new 20d high closing weak on high volume
    upthrust = 0.0
    prior_high = float(high.iloc[-(EXTREME_WIN + RECENT_WIN):-RECENT_WIN].max()) if len(high) >= EXTREME_WIN + RECENT_WIN else float(high.max())
    rhigh = float(recent["High"].max())
    # close position on the day of the recent high
    hi_day = recent["High"].idxmax()
    hh = float(high.loc[hi_day]); ll = float(low.loc[hi_day]); cc = float(close.loc[hi_day])
    hi_pos = (cc - ll) / (hh - ll) if hh > ll else 0.5
    hi_vol = float(vol.loc[hi_day])
    if rhigh > prior_high and hi_pos < 0.33 and hi_vol > avgv:
        upthrust = 1.0

    # store raw components; z-scoring happens cross-sectionally in run()
    return {
        "evr": evr,
        "cs": close_strength,
        "vw": vw_trend,
        "spring": spring,
        "upthrust": upthrust,
    }


def _z(a: np.ndarray) -> np.ndarray:
    m = np.nanmean(a); sd = np.nanstd(a)
    if not math.isfinite(sd) or sd == 0:
        return np.zeros_like(a)
    return (a - m) / sd


def run() -> dict:
    frames = _load_max_us()
    cal = _common_calendar(frames)
    c = COST_BPS / 10000.0

    first = LOOKBACK + SKIP
    last = len(cal) - HOLD - 1

    bench, mom_strat, vpa_strat = [], [], []
    prev_bench: set = set(); prev_mom: set = set(); prev_vpa: set = set()
    n_recs = 0

    for ri in range(first, last + 1, HOLD):
        t = cal[ri]
        t0, t1 = cal[ri - LOOKBACK - SKIP], cal[ri - SKIP]
        t_liq, t_fwd = cal[ri - LIQ_WIN], cal[ri + HOLD]

        names, mom, fwd = [], [], []
        vpa_raw = []
        for tkr, df in frames.items():
            p0 = df["Adj Close"].asof(t0); p1 = df["Adj Close"].asof(t1)
            pn = df["Adj Close"].asof(t); pf = df["Adj Close"].asof(t_fwd)
            if any(pd.isna(x) or x <= 0 for x in (p0, p1, pn, pf)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            comp = _vpa_score(df, t)
            if comp is None:
                continue
            names.append(tkr); mom.append((p1 / p0) - 1.0); fwd.append((pf / pn) - 1.0)
            vpa_raw.append(comp)
        if len(names) < 40:
            continue
        n_recs += 1
        names = np.array(names); mom = np.array(mom); fwd = np.array(fwd)

        # momentum decile
        mom_order = np.argsort(mom)
        k = max(1, len(names) // N_DECILES)
        mom_top = set(names[mom_order[-k:]].tolist())

        # VPA composite: cross-sectionally z-score each component, then sum
        evr = _z(np.array([r["evr"] for r in vpa_raw]))
        cs = _z(np.array([r["cs"] for r in vpa_raw]))
        vw = _z(np.array([r["vw"] for r in vpa_raw]))
        spring = np.array([r["spring"] for r in vpa_raw])
        upthrust = np.array([r["upthrust"] for r in vpa_raw])
        vpa_comp = evr + cs + vw + spring - upthrust
        vpa_order = np.argsort(vpa_comp)
        vpa_top = set(names[vpa_order[-k:]].tolist())

        bench_ret = float(np.mean(fwd))
        mom_ret = float(np.mean(fwd[[i for i, nm in enumerate(names) if nm in mom_top]]))
        vpa_ret = float(np.mean(fwd[[i for i, nm in enumerate(names) if nm in vpa_top]]))

        to_b = _turnover(prev_bench, set(names.tolist()))
        to_m = _turnover(prev_mom, mom_top)
        to_v = _turnover(prev_vpa, vpa_top)
        bench.append(bench_ret - 2 * c * to_b)
        mom_strat.append(mom_ret - 2 * c * to_m)
        vpa_strat.append(vpa_ret - 2 * c * to_v)
        prev_bench = set(names.tolist()); prev_mom = mom_top; prev_vpa = vpa_top

    mom_excess = [s - b for s, b in zip(mom_strat, bench)]
    vpa_excess = [s - b for s, b in zip(vpa_strat, bench)]
    head = [v - m for v, m in zip(vpa_strat, mom_strat)]

    return {
        "universe_symbols": len(frames),
        "rebalances": n_recs,
        "cost_bps_per_side": COST_BPS,
        "data_window": {
            "first": str(cal[first].date()),
            "last": str(cal[min(last, len(cal) - 1)].date()),
        },
        "net_of_cost": {
            "benchmark_equal_weight": _summ(bench),
            "momentum_top_decile": _summ(mom_strat),
            "vpa_wyckoff_top_decile": _summ(vpa_strat),
        },
        "excess_over_benchmark": {
            "momentum": {**_summ(mom_excess), "excess_t": _excess_t(mom_excess)},
            "vpa_wyckoff": {**_summ(vpa_excess), "excess_t": _excess_t(vpa_excess)},
        },
        "vpa_minus_momentum_per_hold": {**_summ(head), "t_stat": _excess_t(head)},
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    p = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(p, "w"), indent=2)
    print("\nwrote", p)
