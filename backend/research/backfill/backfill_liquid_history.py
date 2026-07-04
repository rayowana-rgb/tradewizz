"""Multi-year history backfill for the LIQUID US sub-universe.

WHY: every fragile-signal research question (momentum 12-1, momentum crashes,
regime-guard calibration, evidence ceiling >55) is blocked by our ~1y
single-regime cache. This script lifts that ceiling by fetching long history
(period=max) for ONLY the tradable names -- the only names any of our signals
can actually act on.

RESPECTS THE USER'S HARD LIMITS (do NOT hammer Yahoo):
  * throttle: at most MAX_REQ requests per WINDOW_S seconds (default 14 / 30s).
  * conservative per-request jitter on top.
  * RESUMABLE: skips tickers already cached at the target period+interval, so a
    run can be stopped and restarted without re-fetching.
  * uses the SAME backend fetch path (app.cache OhlcvCache) so results land in
    the normal cache as a SEPARATE (ticker, period, interval) entry -- it does
    NOT overwrite existing 1y data.

Selection of the liquid sub-universe is done from the EXISTING 1y cache (no new
requests): rank US names by median 63d dollar-volume, keep those passing the
liquidity-participation tradability gate, take the top N by ADV.

USAGE (dry-run prints the plan, fetches nothing):
    PYTHONPATH=. .venv/bin/python research/backfill/backfill_liquid_history.py --dry-run
Actual run (only after explicit go-ahead):
    PYTHONPATH=. .venv/bin/python research/backfill/backfill_liquid_history.py --period max --top 800
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import os
import time
from typing import List, Tuple

import numpy as np
import pandas as pd

CACHE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", ".cache", "ohlcv")
)

LIQ_WIN = 63
MIN_BARS = 200
ADV_FLOOR = 100_000.0
ZERO_VOL_MAX = 0.20
DOLLAR_FLOOR = 1_000.0

# Throttle: user hard limit is <= ~14 req / 30s. Stay under it.
MAX_REQ = 14
WINDOW_S = 30.0
JITTER_S = 0.8


def _rank_liquid_universe(top_n: int) -> List[Tuple[str, float]]:
    """From the existing 1y cache, return top_n tradable US tickers by ADV.
    No network requests -- reads local CSVs only."""
    scored: List[Tuple[str, float]] = []
    for meta_path in glob.glob(os.path.join(CACHE, "*.meta.json")):
        try:
            meta = json.load(open(meta_path))
        except Exception:
            continue
        if meta.get("market") != "US" or meta.get("interval") != "1d":
            continue
        if meta.get("period") != "1y":
            continue
        csv_path = meta_path.replace(".meta.json", ".csv")
        tkr = meta.get("ticker")
        if not tkr or not os.path.exists(csv_path):
            continue
        # Exclude index symbols (^GSPC, ^HSI, ...) -- not tradable equities.
        if tkr.startswith("^"):
            continue
        try:
            df = pd.read_csv(csv_path, parse_dates=["Date"])
        except Exception:
            continue
        if not {"Date", "Close", "Volume"}.issubset(df.columns) or len(df) < MIN_BARS:
            continue
        df = df.sort_values("Date")
        w = df.tail(LIQ_WIN)
        dv = (w["Close"] * w["Volume"].clip(lower=0)).astype(float)
        if len(dv) < LIQ_WIN * 0.6:
            continue
        adv = float(np.median(dv))
        zero_frac = float((dv < DOLLAR_FLOOR).mean())
        if adv >= ADV_FLOOR and zero_frac <= ZERO_VOL_MAX and math.isfinite(adv):
            scored.append((tkr, adv))
    scored.sort(key=lambda x: x[1], reverse=True)
    return scored[:top_n]


def _already_cached(cache, tkr: str, period: str, interval: str) -> bool:
    try:
        df = cache.read_cached_only(tkr, period, interval)
        return df is not None and len(df) > MIN_BARS
    except Exception:
        return False


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--period", default="max")
    ap.add_argument("--interval", default="1d")
    ap.add_argument("--top", type=int, default=800)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    universe = _rank_liquid_universe(args.top)
    print(f"liquid tradable US universe (top {args.top} by ADV): {len(universe)} names")
    if universe:
        print(f"  ADV range: ${universe[-1][1]:,.0f} .. ${universe[0][1]:,.0f}")
        print(f"  sample: {[t for t,_ in universe[:8]]}")

    if args.dry_run:
        est_min = len(universe) / MAX_REQ * (WINDOW_S / 60.0)
        print(f"\nDRY RUN -- no requests made.")
        print(f"  would fetch period={args.period} interval={args.interval}")
        print(f"  throttle: {MAX_REQ} req / {WINDOW_S:.0f}s + {JITTER_S}s jitter")
        print(f"  rough time estimate: ~{est_min:.0f} min for {len(universe)} names")
        return

    # Real run: use the backend cache path so results land normally.
    from app.engine import _yf_fetch
    from app.cache import make_cached_fetcher

    fetcher = make_cached_fetcher(_yf_fetch)
    cache = fetcher.cache

    done = skipped = failed = 0
    window_start = time.time()
    window_count = 0
    for i, (tkr, adv) in enumerate(universe, 1):
        if _already_cached(cache, tkr, args.period, args.interval):
            skipped += 1
            continue
        # throttle window
        if window_count >= MAX_REQ:
            elapsed = time.time() - window_start
            if elapsed < WINDOW_S:
                time.sleep(WINDOW_S - elapsed)
            window_start = time.time()
            window_count = 0
        time.sleep(JITTER_S)
        try:
            df = fetcher(tkr, args.period, args.interval)
            window_count += 1
            done += 1
            if done % 25 == 0:
                print(f"  [{i}/{len(universe)}] fetched {tkr}: {len(df)} rows "
                      f"({df.index[0].date()}..{df.index[-1].date()}) "
                      f"| done={done} skip={skipped} fail={failed}")
        except Exception as exc:  # noqa: BLE001
            window_count += 1
            failed += 1
            print(f"  [{i}/{len(universe)}] FAIL {tkr}: {exc}")

    print(f"\nDONE. fetched={done} skipped(cached)={skipped} failed={failed} "
          f"of {len(universe)} names.")


if __name__ == "__main__":
    main()
