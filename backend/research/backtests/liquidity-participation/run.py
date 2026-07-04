"""Stage-3 backtest: Liquidity & Participation Score on the live US cache.

This atom is a FILTER, not a return factor, so we test two falsifiable claims
(see research/atoms/liquidity-participation.md), using real cached data only:

  Claim A (coverage): what fraction of the US universe is non-tradable by our
    gate (median 63d dollar-volume < $100k OR zero/near-zero-volume day
    fraction > 0.2)?

  Claim B (signal hygiene): illiquid names carry stale/noisy prices, so a
    cross-sectional signal should be NOISIER there. We split the universe into
    the liquid half vs illiquid half by liquidity_score and compare the
    information coefficient (Spearman of 3-1 momentum signal vs forward 21d
    return) in each half. Hypothesis: |IC| lower and/or forward-return variance
    higher in the illiquid half.

No look-ahead: signal window and forward window are disjoint. Every number is
computed here. Nothing fabricated. Honest data limit: ~1y, single regime.
"""
from __future__ import annotations

import glob
import json
import math
import os
from typing import Dict, List, Optional

import numpy as np
import pandas as pd

CACHE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", ".cache", "ohlcv")
)

WIN = 63            # liquidity trailing window (~3 months)
LOOKBACK = 63       # 3-1 momentum lookback (fits 1y history w/ forward room)
SKIP = 21
HOLD = 21
MIN_BARS = 200
ADV_FLOOR = 100_000.0   # $100k median daily dollar volume
ZERO_VOL_MAX = 0.20     # >20% near-zero-volume days -> non-tradable
DOLLAR_FLOOR = 1_000.0  # a "near-zero" volume day


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
        need = {"Date", "Adj Close", "Close", "Volume"}
        if not need.issubset(df.columns) or len(df) < MIN_BARS:
            continue
        df = df.set_index("Date").sort_index()
        df = df[(df["Adj Close"] > 0) & (df["Close"] > 0)]
        if len(df) < MIN_BARS:
            continue
        df["dv"] = df["Close"] * df["Volume"].clip(lower=0)
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


def run() -> dict:
    frames = _load_us()
    cal = _common_calendar(frames)

    # --- Claim A: point-in-time tradability at the last full window --------
    asof = cal[-1]
    lo = cal[-WIN]
    tradable = 0
    non_tradable = 0
    liq_rows: List[dict] = []  # for the split test at each rebalance
    adv_all: List[float] = []
    for tkr, df in frames.items():
        w = df.loc[(df.index > lo) & (df.index <= asof)]
        if len(w) < WIN * 0.6:
            continue
        adv = float(np.median(w["dv"]))
        zero_frac = float((w["dv"] < DOLLAR_FLOOR).mean())
        adv_all.append(adv)
        if adv < ADV_FLOOR or zero_frac > ZERO_VOL_MAX:
            non_tradable += 1
        else:
            tradable += 1
    total = tradable + non_tradable
    claim_a = {
        "asof": str(asof.date()),
        "evaluated": total,
        "tradable": tradable,
        "non_tradable": non_tradable,
        "non_tradable_frac": round(non_tradable / total, 4) if total else None,
        "adv_median_of_universe": round(float(np.median(adv_all)), 2) if adv_all else None,
        "adv_p10": round(float(np.percentile(adv_all, 10)), 2) if adv_all else None,
        "adv_p90": round(float(np.percentile(adv_all, 90)), 2) if adv_all else None,
    }

    # --- Claim B: momentum IC in liquid vs illiquid half -------------------
    first = max(LOOKBACK, WIN)
    last = len(cal) - HOLD - 1
    rebal_idx = list(range(first, last + 1, HOLD))
    ic_liquid: List[float] = []
    ic_illiquid: List[float] = []
    var_liquid: List[float] = []
    var_illiquid: List[float] = []

    for ri in rebal_idx:
        t = cal[ri]
        t_lb = cal[ri - LOOKBACK]
        t_skip = cal[ri - SKIP]
        t_win = cal[ri - WIN]
        t_fwd = cal[ri + HOLD]
        recs = []
        for df in frames.values():
            try:
                p_lb = df["Adj Close"].asof(t_lb)
                p_skip = df["Adj Close"].asof(t_skip)
                p_now = df["Adj Close"].asof(t)
                p_fwd = df["Adj Close"].asof(t_fwd)
            except Exception:
                continue
            if any(pd.isna(x) or x <= 0 for x in (p_lb, p_skip, p_now, p_fwd)):
                continue
            w = df.loc[(df.index > t_win) & (df.index <= t)]
            if len(w) < WIN * 0.6:
                continue
            adv = float(np.median(w["dv"]))
            sig = (p_skip / p_lb) - 1.0
            fwd = (p_fwd / p_now) - 1.0
            if not (math.isfinite(sig) and math.isfinite(fwd) and math.isfinite(adv)):
                continue
            recs.append((adv, sig, fwd))
        if len(recs) < 400:
            continue
        arr = np.array(recs)
        med_adv = np.median(arr[:, 0])
        liq = arr[arr[:, 0] >= med_adv]
        illiq = arr[arr[:, 0] < med_adv]
        if len(liq) >= 100 and len(illiq) >= 100:
            ic_liquid.append(_spearman(liq[:, 1], liq[:, 2]))
            ic_illiquid.append(_spearman(illiq[:, 1], illiq[:, 2]))
            var_liquid.append(float(np.var(liq[:, 2])))
            var_illiquid.append(float(np.var(illiq[:, 2])))

    def _mean(x):
        x = [v for v in x if math.isfinite(v)]
        return round(float(np.mean(x)), 4) if x else None

    claim_b = {
        "rebalances": len(ic_liquid),
        "mean_IC_liquid_half": _mean(ic_liquid),
        "mean_IC_illiquid_half": _mean(ic_illiquid),
        "mean_fwd_return_variance_liquid": _mean(var_liquid),
        "mean_fwd_return_variance_illiquid": _mean(var_illiquid),
    }

    return {
        "universe_symbols": len(frames),
        "common_calendar_days": len(cal),
        "data_window": f"{cal[0].date()} .. {cal[-1].date()}",
        "regime_note": "single ~1y regime; NOT multi-regime. Evidence capped.",
        "claim_A_tradability_coverage": claim_a,
        "claim_B_signal_hygiene_by_liquidity": claim_b,
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    out = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(out, "w"), indent=2)
    print("\nwrote", out)
