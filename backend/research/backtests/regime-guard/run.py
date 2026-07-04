"""Stage-3 backtest: Regime Guard on the live US cache.

We built (in prior atoms) a clean-but-fragile SHORT-TERM (1-month) MOMENTUM
signal. This atom tests the WEAK, honestly-testable claim on our ~1y data:

  Does the short-term-momentum edge CONCENTRATE in a 'risk-on / trending'
  regime and weaken/disappear in a 'risk-off' regime?

Method (all real numbers, no look-ahead):
  1. Build an equal-weight market proxy: mean daily Adj-Close return across the
     liquid (tradable) universe on the common calendar.
  2. Label each date:
       trend_state = proxy_level > trailing 100d average  (proxy_level = cum.
                     product of (1+ret))
       vol_state   = trailing 21d realized vol of proxy <= median realized vol
       regime_on   = trend_state AND vol_state
     All using data up to and including date t (no future info).
  3. For each 21d rebalance, compute the short-term-momentum decile spread and
     IC (top decile = recent winners), then bucket the rebalance by the regime
     label at date t.
  4. Compare mean IC / spread in regime_on vs regime_off.

Caveat printed in output: ~1y single regime, few off-dates -> suggestive only.
"""
from __future__ import annotations

import glob
import json
import math
import os
from typing import Dict, List

import numpy as np
import pandas as pd

CACHE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", ".cache", "ohlcv")
)

MOM = 21            # 1-month momentum lookback
HOLD = 21
LIQ_WIN = 63
MIN_BARS = 200
N_DECILES = 10
ADV_FLOOR = 100_000.0
ZERO_VOL_MAX = 0.20
DOLLAR_FLOOR = 1_000.0
TREND_WIN = 100
VOL_WIN = 21


def _load_us() -> Dict[str, pd.DataFrame]:
    out: Dict[str, pd.DataFrame] = {}
    for meta_path in glob.glob(os.path.join(CACHE, "*.meta.json")):
        try:
            meta = json.load(open(meta_path))
        except Exception:
            continue
        if meta.get("market") != "US" or meta.get("interval") != "1d":
            continue
        csv_path = meta_path.replace(".meta.json", ".csv")
        if not os.path.exists(csv_path):
            continue
        try:
            df = pd.read_csv(csv_path, parse_dates=["Date"])
        except Exception:
            continue
        if not {"Date", "Adj Close", "Close", "Volume"}.issubset(df.columns) or len(df) < MIN_BARS:
            continue
        df = df.set_index("Date").sort_index()
        df = df[(df["Adj Close"] > 0) & (df["Close"] > 0)]
        if len(df) < MIN_BARS:
            continue
        df["dv"] = df["Close"] * df["Volume"].clip(lower=0)
        df["ret"] = df["Adj Close"].pct_change()
        out[meta.get("ticker") or os.path.basename(csv_path)] = df
    return out


def _common_calendar(frames: Dict[str, pd.DataFrame]) -> pd.DatetimeIndex:
    counts: Dict[pd.Timestamp, int] = {}
    for df in frames.values():
        for d in df.index:
            counts[d] = counts.get(d, 0) + 1
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


def _build_proxy(frames: Dict[str, pd.DataFrame], cal: pd.DatetimeIndex) -> pd.DataFrame:
    # Equal-weight mean daily return across tradable names, per calendar date.
    rets: Dict[pd.Timestamp, List[float]] = {d: [] for d in cal}
    for df in frames.values():
        sub = df[df.index.isin(cal)]
        for d, r in sub["ret"].items():
            if math.isfinite(r):
                rets[d].append(float(r))
    rows = []
    for d in cal:
        vals = rets[d]
        rows.append((d, float(np.mean(vals)) if vals else 0.0, len(vals)))
    proxy = pd.DataFrame(rows, columns=["Date", "ret", "n"]).set_index("Date")
    proxy["level"] = (1.0 + proxy["ret"]).cumprod()
    proxy["ma"] = proxy["level"].rolling(TREND_WIN).mean()
    proxy["rvol"] = proxy["ret"].rolling(VOL_WIN).std()
    proxy["rvol_med"] = proxy["rvol"].expanding(min_periods=VOL_WIN + 5).median()
    proxy["trend_on"] = proxy["level"] > proxy["ma"]
    proxy["vol_on"] = proxy["rvol"] <= proxy["rvol_med"]
    proxy["regime_on"] = proxy["trend_on"] & proxy["vol_on"]
    return proxy


def run() -> dict:
    frames = _load_us()
    cal = _common_calendar(frames)
    proxy = _build_proxy(frames, cal)

    first = max(MOM, LIQ_WIN, TREND_WIN)
    last = len(cal) - HOLD - 1
    rebal_idx = list(range(first, last + 1, HOLD))

    buckets = {"regime_on": {"ic": [], "tmb": []}, "regime_off": {"ic": [], "tmb": []}}
    labels = []

    for ri in rebal_idx:
        t = cal[ri]
        t_mom = cal[ri - MOM]
        t_liq = cal[ri - LIQ_WIN]
        t_fwd = cal[ri + HOLD]
        row = proxy.loc[t]
        if pd.isna(row["ma"]) or pd.isna(row["rvol_med"]):
            continue
        regime_on = bool(row["regime_on"])
        recs = []
        for df in frames.values():
            try:
                p_mom = df["Adj Close"].asof(t_mom)
                p_now = df["Adj Close"].asof(t)
                p_fwd = df["Adj Close"].asof(t_fwd)
            except Exception:
                continue
            if any(pd.isna(x) or x <= 0 for x in (p_mom, p_now, p_fwd)):
                continue
            if not _is_tradable(df, t_liq, t):
                continue
            sig = (p_now / p_mom) - 1.0     # momentum: recent winners rank high
            fwd = (p_fwd / p_now) - 1.0
            if math.isfinite(sig) and math.isfinite(fwd):
                recs.append((sig, fwd))
        if len(recs) < 200:
            continue
        arr = np.array(recs)
        order = np.argsort(arr[:, 0])
        bkt = np.array_split(order, N_DECILES)
        dfwd = np.array([arr[b, 1].mean() for b in bkt])
        tmb = float(dfwd[-1] - dfwd[0])
        ic = _spearman(arr[:, 0], arr[:, 1])
        key = "regime_on" if regime_on else "regime_off"
        buckets[key]["ic"].append(ic)
        buckets[key]["tmb"].append(tmb)
        labels.append({"date": str(t.date()), "regime_on": regime_on,
                       "trend_on": bool(row["trend_on"]), "vol_on": bool(row["vol_on"]),
                       "ic": round(ic, 4), "tmb": round(tmb, 4)})

    def _summ(d):
        ic = [x for x in d["ic"] if math.isfinite(x)]
        tmb = [x for x in d["tmb"] if math.isfinite(x)]
        return {
            "rebalances": len(tmb),
            "mean_ic": round(float(np.mean(ic)), 4) if ic else None,
            "mean_top_minus_bottom_per_hold": round(float(np.mean(tmb)), 4) if tmb else None,
            "spread_hit_rate": round(float(np.mean([1 if x > 0 else 0 for x in tmb])), 4) if tmb else None,
        }

    on_frac = round(float(proxy["regime_on"].mean()), 4)
    return {
        "universe_symbols": len(frames),
        "common_calendar_days": len(cal),
        "data_window": f"{cal[0].date()} .. {cal[-1].date()}",
        "regime_note": "single ~1y regime; few off-dates; SUGGESTIVE only, NOT conclusive.",
        "proxy": "equal-weight mean daily return across tradable US names",
        "regime_on_fraction_of_days": on_frac,
        "signal": "1-month cross-sectional MOMENTUM (recent winners rank high), tradable-only",
        "regime_on": _summ(buckets["regime_on"]),
        "regime_off": _summ(buckets["regime_off"]),
        "per_rebalance": labels,
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    out = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(out, "w"), indent=2)
    print("\nwrote", out)
