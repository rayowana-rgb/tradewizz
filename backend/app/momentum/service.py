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
# Memoise the full ranking this long. Rebalance is monthly and the underlying
# OHLCV cache updates at most daily, so a fresh scan every 30 min is plenty and
# keeps the request well under the app timeout after the first (cold) call.
RESULT_TTL_SECONDS = 1800

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


# Rebalance cadence: the production spec is a MONTHLY hold (~21 trading days).
REBALANCE_TRADING_DAYS = 21


@dataclass(frozen=True)
class RebalanceSchedule:
    """When the next monthly momentum rebalance is due.

    All dates are honest: `last_rebalance` comes from the real ledger mutation
    time (None if no momentum position was ever taken), and the due date is
    computed on the actual exchange calendar (21 TRADING days, not 21 calendar
    days) drawn from the cached OHLCV series. When there is no ledger clock yet,
    `status` is "none" and no date is fabricated.
    """

    status: str                 # "none" | "due" | "upcoming"
    last_rebalance_date: Optional[str]   # ISO date of last momentum action
    due_date: Optional[str]              # ISO date the next rebalance is due
    trading_days_remaining: Optional[int]  # <=0 means due/overdue
    note: str


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
        # Result cache. Scanning 300+ symbols off disk takes ~30s, which blew
        # past the app's request timeout and made the page "load forever". The
        # ranking only changes when the daily OHLCV cache updates, so we memoise
        # the full sorted result and slice per top_n. Thread-safe enough for the
        # single-worker uvicorn deployment.
        self._cached: Optional[tuple[float, list, str, str, int, int]] = None

    def invalidate(self) -> None:
        """Drop the memoised ranking (e.g. after a cache refresh)."""
        self._cached = None

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
    def _compute_rows(self):
        """Full scan: returns (sorted_rows, regime, regime_note, usable, tradable).
        Expensive (~30s over 300+ names); callers should go through the cache."""
        symbols = self._universe.symbols(Market.US)
        return self._scan(symbols)

    def picks(self, top_n: int = DEFAULT_TOP_N) -> MomentumPicks:
        from datetime import datetime, timezone
        import time

        n = max(1, min(int(top_n or DEFAULT_TOP_N), MAX_TOP_N))

        now = time.time()
        cached = self._cached
        if cached is not None and (now - cached[0]) < RESULT_TTL_SECONDS:
            _, rows, regime, regime_note, usable, tradable = cached
        else:
            rows, regime, regime_note, usable, tradable = self._compute_rows()
            self._cached = (now, rows, regime, regime_note, usable, tradable)

        top = [
            MomentumPick(
                symbol=r.symbol, rank=i + 1, momentum=round(r.momentum, 4),
                last_price=r.last_price, median_dollar_vol=r.median_dollar_vol,
            )
            for i, r in enumerate(rows[:n])
        ]
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

    # -- rebalance schedule ------------------------------------------------ #
    def _trading_calendar(self, max_symbols: int = 30):
        """A recent exchange-trading-day calendar from the cached liquid names.

        Uses the SAME cache-only reads as the picks (no network). Unions the
        recent index dates across a handful of the deepest series so a single
        symbol's gap cannot distort the calendar. Returns a sorted list of
        `datetime.date`.
        """
        from datetime import date as _date
        seen: set = set()
        count = 0
        for sym in self._universe.symbols(Market.US):
            df = self._frame(sym)
            if df is None:
                continue
            try:
                for ts in df.index[-400:]:
                    seen.add(pd.Timestamp(ts).date())
            except Exception:  # noqa: BLE001
                continue
            count += 1
            if count >= max_symbols:
                break
        return sorted(d for d in seen if isinstance(d, _date))

    def rebalance_schedule(self, last_rebalance_ts: Optional[int]) -> RebalanceSchedule:
        """Compute the next monthly rebalance date from the last ledger action.

        `last_rebalance_ts` is epoch seconds (from the momentum ledger), or None
        when no momentum position has ever been taken. The due date is the
        trading day that is REBALANCE_TRADING_DAYS exchange sessions after the
        session containing the last action -- computed on the real cached
        exchange calendar, never a naive +30 calendar days.
        """
        from datetime import datetime, timezone, date as _date

        if not last_rebalance_ts:
            return RebalanceSchedule(
                status="none",
                last_rebalance_date=None,
                due_date=None,
                trading_days_remaining=None,
                note=(
                    "No momentum position taken yet. The monthly-rebalance clock "
                    "starts on your first momentum buy."
                ),
            )

        last_dt = datetime.fromtimestamp(int(last_rebalance_ts), tz=timezone.utc).date()
        cal = self._trading_calendar()
        if len(cal) < REBALANCE_TRADING_DAYS + 2:
            return RebalanceSchedule(
                status="none",
                last_rebalance_date=last_dt.isoformat(),
                due_date=None,
                trading_days_remaining=None,
                note="Not enough cached trading history to project the due date.",
            )

        today = datetime.now(timezone.utc).date()

        # Index of the session on/after the last action within the calendar.
        def _idx_on_or_after(d: _date) -> int:
            for i, cd in enumerate(cal):
                if cd >= d:
                    return i
            return len(cal) - 1

        import datetime as _dt

        def _weekday_sessions_between(a: _date, b: _date) -> int:
            """Approx trading sessions from a to b (exclusive) counting weekdays."""
            if b <= a:
                return 0
            n = 0
            d = a
            while d < b:
                d = d + _dt.timedelta(days=1)
                if d.weekday() < 5:
                    n += 1
            return n

        # A single "virtual" session-index function that works both inside the
        # cached calendar AND past its end (the daily backfill can lag the real
        # clock by a few days). Past the end we extend by counting weekdays, so
        # last-action, today, and due dates are all measured on ONE consistent
        # session axis and stay ordered correctly.
        last_cal = cal[-1]

        def _session_index(d: _date) -> int:
            if d <= last_cal:
                return _idx_on_or_after(d)
            return (len(cal) - 1) + _weekday_sessions_between(last_cal, d)

        def _date_for_index(i: int) -> _date:
            if i < len(cal):
                return cal[max(0, i)]
            over = i - (len(cal) - 1)
            d = last_cal
            added = 0
            while added < over:
                d = d + _dt.timedelta(days=1)
                if d.weekday() < 5:
                    added += 1
            return d

        last_idx = _session_index(last_dt)
        due_idx = last_idx + REBALANCE_TRADING_DAYS
        today_idx = _session_index(today)

        due_date = _date_for_index(due_idx)
        remaining = due_idx - today_idx  # trading sessions from today to due

        status = "due" if remaining <= 0 else "upcoming"
        if status == "due":
            note = (
                "Monthly rebalance is due. Review the current top-N and rebalance "
                "to keep the book aligned with the signal."
            )
        else:
            note = (
                f"Next monthly rebalance in ~{remaining} trading day"
                f"{'s' if remaining != 1 else ''}."
            )
        return RebalanceSchedule(
            status=status,
            last_rebalance_date=last_dt.isoformat(),
            due_date=due_date.isoformat(),
            trading_days_remaining=int(remaining),
            note=note,
        )

    def _scan(self, symbols):

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
        regime, regime_note = self._regime(level_tails)
        return rows, regime, regime_note, usable, tradable

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
