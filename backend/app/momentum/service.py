"""Momentum picks service -- the Stage-3b production spec, served live.

Production spec (research/production-candidate.md), all validated on history:
  - Universe: liquid US equities (tradability gate).
  - Signal:   12-1 momentum = trailing 252d total return, SKIPPING the most
              recent 21 trading days (avoids short-term reversal).
  - Selection: long-only, EQUAL-WEIGHT top-N by the signal.
  - Rebalance: monthly (~21 trading days).
  - Exit:     NO tight intraday stop. The monthly rebalance IS the exit.
              (SL-1%/TP+3% was PROVEN to destroy the edge -- 2026-07-04d.)

We ALSO expose a market-regime flag (equal-weight-market vs its 200d SMA). It
does not change the picks; it tells the user when the validated crash-recovery
overlay would engage (2026-07-04j). Purely informational.

Reads the SAME on-disk OHLCV cache the rest of the backend uses (period=1y,
interval=1d) via read-cached-only -- NEVER triggers a network fetch on a request
path. Symbols without enough cached history are skipped (honest: no fabricated
data). This is a read-only ranking; it places no orders.
"""
from __future__ import annotations

import logging
import math
from dataclasses import dataclass
from typing import List, Optional

import numpy as np
import pandas as pd

from ..models import Market
from ..universe import UniverseRepository

logger = logging.getLogger("tradewiz.momentum")

# --- Stage-3b production-spec constants (do NOT tune casually) ------------- #
LOOKBACK = 252          # trailing return window (trading days)
SKIP = 21               # skip most-recent month (short-term reversal)
LIQ_WIN = 63            # liquidity window for the tradability gate
MIN_BARS = LOOKBACK + SKIP + 5
ADV_FLOOR = 100_000.0   # median dollar-volume floor
ZERO_VOL_MAX = 0.20     # max fraction of near-zero-volume days
DOLLAR_FLOOR = 1_000.0
SMA_WIN = 200           # regime filter window
DEFAULT_TOP_N = 10
MAX_TOP_N = 25
# Robustness guard: a 12-1 total return above this is almost always a corporate-
# action / split / spinoff adjustment ARTIFACT in the cached series rather than a
# real, tradable move. We drop such names so a data glitch can never become a
# real-money basket pick. (Genuine ~10x movers over a year are astronomically
# rare and, if real, would still be too illiquid/risky for a systematic book.)
MOM_SANITY_CAP = 4.0    # +400% over 12-1; above this = reject as artifact
MOM_FLOOR = -0.95       # guard against fully-broken series

# Honest metadata surfaced to the UI so nobody mistakes this for a live-proven,
# production-promoted signal.
STAGE = "backtest-oos"
DISCLAIMER = (
    "EXPERIMENTAL research signal (Stage-3b). Long-only top-N by 12-1 momentum, "
    "monthly hold, no tight stop. Passed historical out-of-sample (excess TEST "
    "t=2.49) but NOT live-validated. Real orders risk real money."
)


@dataclass(frozen=True)
class MomentumPick:
    symbol: str
    rank: int
    momentum: float          # 12-1 total return (decimal)
    last_price: float
    median_dollar_vol: float


@dataclass(frozen=True)
class MomentumPicks:
    picks: List[MomentumPick]
    universe_size: int        # symbols with usable cached history
    tradable_size: int        # symbols passing the liquidity gate
    top_n: int
    regime: str               # "bull" | "stress"
    regime_note: str
    stage: str
    disclaimer: str
    generated_at: str


class MomentumService:
    """Computes live momentum picks from the shared read-only OHLCV cache."""

    def __init__(self, cache, universe: Optional[UniverseRepository] = None):
        # `cache` is an OhlcvCache (has read_cached_only). Injected so tests can
        # substitute a fake without touching disk.
        self._cache = cache
        self._universe = universe or UniverseRepository()

    # -- helpers ----------------------------------------------------------- #
    def _frame(self, symbol: str) -> Optional[pd.DataFrame]:
        # Prefer deep `max` history (the ~344 liquid backfilled names) so the
        # 12-1 window (252d + 21d skip) fits; fall back to 1y. 1y (~252 bars)
        # alone is too short for lookback+skip, so those symbols are skipped
        # honestly rather than computed on truncated data.
        df = None
        for period in ("max", "1y"):
            try:
                cand = self._cache.read_cached_only(
                    symbol, period=period, interval="1d"
                )
            except Exception:  # noqa: BLE001 - one bad symbol must not break the run
                cand = None
            if cand is not None and len(cand) >= MIN_BARS:
                df = cand
                break
        if df is None or len(df) < MIN_BARS:
            return None
        cols = {"Adj Close", "Close", "Volume"}
        if not cols.issubset(df.columns):
            return None
        df = df.sort_index()
        df = df[(df["Adj Close"] > 0) & (df["Close"] > 0)]
        if len(df) < MIN_BARS:
            return None
        return df

    @staticmethod
    def _tradable(df: pd.DataFrame) -> tuple[bool, float]:
        w = df.tail(LIQ_WIN)
        dv = (w["Close"] * w["Volume"].clip(lower=0))
        if len(w) < LIQ_WIN * 0.6:
            return False, 0.0
        adv = float(np.median(dv))
        zero_frac = float((dv < DOLLAR_FLOOR).mean())
        ok = (adv >= ADV_FLOOR) and (zero_frac <= ZERO_VOL_MAX)
        return ok, adv

    @staticmethod
    def _momentum_12_1(df: pd.DataFrame) -> Optional[float]:
        px = df["Adj Close"]
        if len(px) < LOOKBACK + SKIP + 1:
            return None
        p_now = float(px.iloc[-1 - SKIP])      # skip most-recent 21 days
        p_then = float(px.iloc[-1 - SKIP - LOOKBACK])
        if p_then <= 0 or not math.isfinite(p_now) or not math.isfinite(p_then):
            return None
        return (p_now / p_then) - 1.0

    # -- public ------------------------------------------------------------ #
    def picks(self, top_n: int = DEFAULT_TOP_N) -> MomentumPicks:
        from datetime import datetime, timezone

        n = max(1, min(int(top_n or DEFAULT_TOP_N), MAX_TOP_N))
        symbols = self._universe.symbols(Market.US)

        rows: List[MomentumPick] = []
        mkt_last_returns: List[float] = []   # for a crude regime read
        usable = 0
        tradable = 0
        # For the SMA200 regime read we build an equal-weight market proxy from
        # the tradable names' own recent levels (cheap, cache-only).
        level_tails: List[pd.Series] = []

        for sym in symbols:
            df = self._frame(sym)
            if df is None:
                continue
            usable += 1
            ok, adv = self._tradable(df)
            if not ok:
                continue
            mom = self._momentum_12_1(df)
            if mom is None:
                continue
            # Reject implausible values almost certainly caused by split/spinoff
            # adjustment artifacts in the cached series (protects real money).
            if mom > MOM_SANITY_CAP or mom < MOM_FLOOR:
                continue
            tradable += 1
            last = float(df["Adj Close"].iloc[-1])
            rows.append(MomentumPick(
                symbol=sym, rank=0, momentum=mom,
                last_price=round(last, 4),
                median_dollar_vol=round(adv, 0),
            ))
            # normalised recent level tail for the regime proxy
            tail = df["Adj Close"].tail(SMA_WIN + 5)
            if len(tail) >= SMA_WIN:
                level_tails.append((tail / tail.iloc[0]).reset_index(drop=True))

        rows.sort(key=lambda r: r.momentum, reverse=True)
        top = [
            MomentumPick(
                symbol=r.symbol, rank=i + 1, momentum=round(r.momentum, 4),
                last_price=r.last_price, median_dollar_vol=r.median_dollar_vol,
            )
            for i, r in enumerate(rows[:n])
        ]

        regime, regime_note = self._regime(level_tails)

        return MomentumPicks(
            picks=top,
            universe_size=usable,
            tradable_size=tradable,
            top_n=n,
            regime=regime,
            regime_note=regime_note,
            stage=STAGE,
            disclaimer=DISCLAIMER,
            generated_at=datetime.now(timezone.utc).isoformat(),
        )

    @staticmethod
    def _regime(level_tails: List[pd.Series]) -> tuple[str, str]:
        """Equal-weight market proxy vs its 200d SMA. Informational only."""
        if len(level_tails) < 20:
            return "unknown", "Not enough cached history to read market regime."
        m = min(len(s) for s in level_tails)
        mat = np.vstack([s.iloc[-m:].to_numpy() for s in level_tails])
        mkt = mat.mean(axis=0)
        if len(mkt) < SMA_WIN:
            return "unknown", "Not enough cached history to read market regime."
        sma = float(np.mean(mkt[-SMA_WIN:]))
        lvl = float(mkt[-1])
        if lvl >= sma:
            return "bull", (
                "Market above its 200d SMA -> pure momentum. The crash-recovery "
                "overlay is idle."
            )
        return "stress", (
            "Market below its 200d SMA -> the validated crash-recovery overlay "
            "would tilt toward long-term reversal (2026-07-04j)."
        )
