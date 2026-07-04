"""Stage-3 backtest: Cross-Sectional Price Momentum (12-1) on the live US cache.

Honest scope (see research/pipeline.md):
  * Data = ~1 trading year of daily US equities (single regime).
  * We measure the CROSS-SECTIONAL decile spread, decile monotonicity, hit
    rate, and the rank information coefficient (IC) of the 12-1 signal vs the
    forward ~21-day return.
  * We DO NOT claim multi-regime Sharpe / true max drawdown — insufficient
    history. Evidence is capped accordingly.

No look-ahead: the signal on date t uses returns up to t (t-252..t-21); the
outcome uses forward returns t..t+H, disjoint from the signal window.

Every number printed is computed here from real cached data. Nothing is
fabricated. Failed/uninteresting results are reported as-is.
"""
from __future__ import annotations

import glob
import json
import math
import os
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd

CACHE = os.path.join(os.path.dirname(__file__), "..", "..", "..", ".cache", "ohlcv")
CACHE = os.path.abspath(CACHE)

# NOTE ON DATA LIMIT: the live cache holds ~1 trading year, so a 12-1 lookback
# (252d) leaves no room for a forward window. We therefore test the 6-1 and 3-1
# variants, both of which are standard in Jegadeesh-Titman (1993), which fit the
# available history and leave room for multiple disjoint forward windows.
SKIP = 21        # skip most recent ~1 month (avoid short-term reversal)
HOLD = 21        # forward holding horizon (~1 month)
MIN_BARS = 200
N_DECILES = 10

# (lookback_days, label) variants to evaluate.
VARIANTS = [(126, "6-1"), (63, "3-1")]
LOOKBACK = 126   # default; overridden per-variant in run()


def _load_us_frames() -> Dict[str, pd.Series]:
    """Return {ticker: Adj Close series indexed by date} for US 1d symbols."""
    out: Dict[str, pd.Series] = {}
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
        if "Adj Close" not in df.columns or len(df) < MIN_BARS:
            continue
        s = df.set_index("Date")["Adj Close"].astype(float).dropna()
        s = s[s > 0]
        if len(s) < MIN_BARS:
            continue
        tkr = meta.get("ticker") or os.path.basename(csv_path)
        out[tkr] = s
    return out


def _common_calendar(frames: Dict[str, pd.Series]) -> pd.DatetimeIndex:
    counts: Dict[pd.Timestamp, int] = {}
    for s in frames.values():
        for d in s.index:
            counts[d] = counts.get(d, 0) + 1
    n = len(frames)
    # keep dates present for a healthy majority of names
    days = sorted(d for d, c in counts.items() if c >= 0.6 * n)
    return pd.DatetimeIndex(days)


def _spearman(a: np.ndarray, b: np.ndarray) -> float:
    ra = pd.Series(a).rank().values
    rb = pd.Series(b).rank().values
    if np.std(ra) == 0 or np.std(rb) == 0:
        return float("nan")
    return float(np.corrcoef(ra, rb)[0, 1])


def run_variant(frames: Dict[str, pd.Series], cal: pd.DatetimeIndex,
                lookback: int, label: str) -> Optional[dict]:
    LOOKBACK = lookback
    if len(cal) < LOOKBACK + HOLD + 5:
        return None

    # Rebalance dates: every HOLD days, once we have a full lookback and a full
    # forward window ahead.
    first = LOOKBACK
    last = len(cal) - HOLD - 1
    rebal_idx = list(range(first, last + 1, HOLD))

    per_reb: List[dict] = []
    ic_list: List[float] = []
    top_minus_bottom: List[float] = []
    decile_fwd: List[np.ndarray] = []  # each row: mean fwd ret per decile

    for ri in rebal_idx:
        t = cal[ri]
        t_lb = cal[ri - LOOKBACK]
        t_skip = cal[ri - SKIP]
        t_fwd = cal[ri + HOLD]

        signals: List[float] = []
        fwds: List[float] = []
        for s in frames.values():
            try:
                p_lb = s.asof(t_lb)
                p_skip = s.asof(t_skip)
                p_now = s.asof(t)
                p_fwd = s.asof(t_fwd)
            except Exception:
                continue
            if any(pd.isna(x) or x <= 0 for x in (p_lb, p_skip, p_now, p_fwd)):
                continue
            sig = (p_skip / p_lb) - 1.0        # 12-1 momentum
            fwd = (p_fwd / p_now) - 1.0        # forward return (disjoint)
            if not (math.isfinite(sig) and math.isfinite(fwd)):
                continue
            signals.append(sig)
            fwds.append(fwd)

        if len(signals) < 200:
            continue
        sig_arr = np.array(signals)
        fwd_arr = np.array(fwds)

        ic = _spearman(sig_arr, fwd_arr)
        # deciles by signal
        order = np.argsort(sig_arr)
        buckets = np.array_split(order, N_DECILES)
        dfwd = np.array([fwd_arr[b].mean() for b in buckets])
        tmb = dfwd[-1] - dfwd[0]

        ic_list.append(ic)
        top_minus_bottom.append(tmb)
        decile_fwd.append(dfwd)
        per_reb.append({
            "date": str(t.date()),
            "n": len(signals),
            "ic": round(ic, 4),
            "top_decile_fwd": round(float(dfwd[-1]), 4),
            "bottom_decile_fwd": round(float(dfwd[0]), 4),
            "top_minus_bottom": round(float(tmb), 4),
        })

    if not per_reb:
        return None

    tmb = np.array(top_minus_bottom)
    ic = np.array([x for x in ic_list if math.isfinite(x)])
    mean_dfwd = np.mean(np.vstack(decile_fwd), axis=0)

    # Monotonicity: Spearman of decile index vs mean forward return.
    mono = _spearman(np.arange(N_DECILES), mean_dfwd)

    # Hit rate: fraction of rebalances where top-minus-bottom > 0.
    hit = float((tmb > 0).mean())

    # t-stat of the mean spread (independent-ish across HOLD-spaced rebalances).
    n = len(tmb)
    tstat = float(tmb.mean() / (tmb.std(ddof=1) / math.sqrt(n))) if n > 1 and tmb.std(ddof=1) > 0 else float("nan")

    result = {
        "variant": label,
        "universe_symbols": len(frames),
        "common_calendar_days": len(cal),
        "rebalances": n,
        "hold_days": HOLD,
        "lookback_days": LOOKBACK,
        "skip_days": SKIP,
        "mean_ic": round(float(ic.mean()), 4),
        "ic_stability_frac_positive": round(float((ic > 0).mean()), 4),
        "mean_top_minus_bottom_per_hold": round(float(tmb.mean()), 4),
        "spread_hit_rate": round(hit, 4),
        "spread_tstat": round(tstat, 3),
        "decile_monotonicity_spearman": round(float(mono), 4),
        "mean_forward_return_by_decile": [round(float(x), 4) for x in mean_dfwd],
        "per_rebalance": per_reb,
    }
    return result


def run() -> dict:
    frames = _load_us_frames()
    cal = _common_calendar(frames)
    variants = []
    for lb, label in VARIANTS:
        r = run_variant(frames, cal, lb, label)
        if r is not None:
            variants.append(r)
    if not variants:
        raise SystemExit(
            f"No variant fit the {len(cal)}-day common calendar."
        )
    return {
        "universe_symbols": len(frames),
        "common_calendar_days": len(cal),
        "data_window": f"{cal[0].date()} .. {cal[-1].date()}",
        "regime_note": "single ~1y regime; NOT multi-regime. Evidence capped.",
        "variants": variants,
    }


if __name__ == "__main__":
    res = run()
    print(json.dumps(res, indent=2))
    out = os.path.join(os.path.dirname(__file__), "results.json")
    json.dump(res, open(out, "w"), indent=2)
    print("\nwrote", out)
