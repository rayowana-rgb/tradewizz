"""Daily OHLCV cache warmer (per-market, market-close triggered, throttled).

Goal
----
When a market's regular session closes for the day, pre-fetch that market's
universe OHLCV into the SAME on-disk cache that ``/analyze`` and the screener
already read from, **gradually** so we never hammer Yahoo. The screener then
serves results computed by the existing engine straight from warm cache.

Design constraints honoured:
  * Each index closes at a DIFFERENT local time (see ``market_session._SESSIONS``).
    The warmer watches every market independently and only warms one once it has
    actually closed for the current trading date.
  * Gradual / lightweight: symbols are fetched one at a time with a configurable
    inter-fetch delay (throttle). Markets are warmed sequentially so two large
    universes never fetch in parallel.
  * Idempotent per trading date: a market is warmed at most once per trading
    date. Reopening the app many times does not re-trigger a warm.
  * Read-only w.r.t. scoring/engine/indicators/data-source: it delegates the
    fetch to an injected ``fetch_symbol`` callable (the engine's cached
    fetcher), so this stays a thin pre-warm loop around existing behaviour.
  * Opt-in: disabled unless ``TRADEWIZZ_ENABLE_DAILY_WARMER`` is truthy, and
    always disabled under pytest, so it never surprises prod or slows tests.

It does NOT compute or store screener output; it only ensures the per-symbol
OHLCV cache is fresh for the just-closed trading date. The existing
``screener_cache`` layer continues to cache the engine's *output*.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from typing import Callable, Dict, List, Optional

from ..market_session import (
    MarketSessionState,
    get_market_session_state,
    trading_date_str,
)
from ..models import Market
from .archive import DailyOhlcvArchive

logger = logging.getLogger("tradewiz.warmer")

# (symbol, market) -> fetch into cache, returning the OHLCV DataFrame (or None).
# Returning the frame lets the warmer also archive it day-by-day; a None/raise
# is tolerated (the symbol is simply not archived).
FetchSymbol = Callable[[str, Market], object]
# market -> list of bare symbols in that market's universe.
SymbolsFor = Callable[[Market], List[str]]


def _env_flag(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def warmer_enabled() -> bool:
    """True only when explicitly opted in and not running under pytest."""
    if os.environ.get("PYTEST_CURRENT_TEST"):
        return False
    return _env_flag("TRADEWIZZ_ENABLE_DAILY_WARMER", default=False)


# Default throttle: ~0.4s between symbol fetches (~2.5 symbols/sec). Tunable.
DEFAULT_FETCH_DELAY_SECONDS = 0.4
# Markets warmed by default: ALL markets. Override via TRADEWIZZ_WARMER_MARKETS.
DEFAULT_MARKETS: List[Market] = list(Market)


def _markets_from_env(default: List[Market]) -> List[Market]:
    raw = os.environ.get("TRADEWIZZ_WARMER_MARKETS")
    if not raw:
        return default
    out: List[Market] = []
    for tok in raw.split(","):
        tok = tok.strip().upper()
        if not tok:
            continue
        try:
            out.append(Market(tok))
        except ValueError:
            logger.warning("warmer: unknown market %r in TRADEWIZZ_WARMER_MARKETS", tok)
    return out or default


class DailyCacheWarmer:
    """Background thread that warms each market's OHLCV cache after its close.

    The thread wakes every ``tick_seconds`` and, for each configured market,
    checks whether the market has closed for the current trading date and has
    not yet been warmed for that date. If so it warms that market's universe
    gradually, then records the completed (market, trading_date).
    """

    def __init__(
        self,
        *,
        fetch_symbol: FetchSymbol,
        symbols_for: SymbolsFor,
        markets: Optional[List[Market]] = None,
        fetch_delay_seconds: Optional[float] = None,
        tick_seconds: float = 60.0,
        clock=time.monotonic,
        now_provider: Optional[Callable[[Market], object]] = None,
        archive: Optional[DailyOhlcvArchive] = None,
    ) -> None:
        self._fetch_symbol = fetch_symbol
        self._symbols_for = symbols_for
        # Day-keyed archive (default: 30-day rolling retention). When set, each
        # warmed symbol's frame is also stored per (market, trading_date) and
        # old days are purged after each market warm.
        self._archive = archive if archive is not None else DailyOhlcvArchive()
        self._markets = markets or _markets_from_env(DEFAULT_MARKETS)
        self._delay = (
            fetch_delay_seconds
            if fetch_delay_seconds is not None
            else _env_float("TRADEWIZZ_WARMER_DELAY_SECONDS", DEFAULT_FETCH_DELAY_SECONDS)
        )
        # Optional cap on symbols per market per run (0 = no cap). Useful to
        # spread a giant universe across multiple days if desired.
        self._max_symbols = _env_int("TRADEWIZZ_WARMER_MAX_SYMBOLS", 0)
        self._tick_seconds = tick_seconds
        self._clock = clock
        self._now_provider = now_provider
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        # (market_code, trading_date) already warmed this process lifetime.
        self._done: Dict[str, str] = {}
        self._lock = threading.Lock()
        # Diagnostics.
        self.last_warm: Dict[str, dict] = {}

    # -- lifecycle ----------------------------------------------------------
    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._run, name="ohlcv-cache-warmer", daemon=True
        )
        self._thread.start()
        logger.info(
            "warmer: started (markets=%s delay=%.2fs)",
            [m.value for m in self._markets], self._delay,
        )

    def stop(self, timeout: float = 2.0) -> None:
        self._stop.set()
        t = self._thread
        if t and t.is_alive():
            t.join(timeout=timeout)
        self._thread = None

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.tick()
            except Exception:  # noqa: BLE001 — best effort, keep looping
                logger.exception("warmer: tick failed")
            self._stop.wait(self._tick_seconds)

    # -- scheduling ---------------------------------------------------------
    def _market_now(self, market: Market):
        if self._now_provider is not None:
            return self._now_provider(market)
        return None  # get_market_session_state() falls back to live clock

    def _is_closed_for_today(self, market: Market) -> bool:
        """True once the regular session has ended for the current trading date.

        POST_MARKET and CLOSED both count as "the day's regular session is done"
        — the candles are final enough to warm. We deliberately warm as soon as
        the regular close passes (POST_MARKET) so results are ready early.
        """
        now = self._market_now(market)
        state = get_market_session_state(market, now)
        return state in (
            MarketSessionState.POST_MARKET,
            MarketSessionState.CLOSED,
        )

    def _already_warmed(self, market: Market, trading_date: str) -> bool:
        with self._lock:
            return self._done.get(market.value) == trading_date

    def _mark_warmed(self, market: Market, trading_date: str) -> None:
        with self._lock:
            self._done[market.value] = trading_date

    def tick(self, *, force_market: Optional[Market] = None) -> List[str]:
        """One scheduling pass. Returns market codes warmed this pass.

        Markets are processed sequentially, so a tick warms at most the markets
        that are due; a single huge universe is fetched gradually within
        ``_warm_market`` (which itself yields to ``_stop``).
        """
        warmed: List[str] = []
        markets = [force_market] if force_market is not None else self._markets
        for market in markets:
            if self._stop.is_set():
                break
            now = self._market_now(market)
            trading_date = trading_date_str(market, now)
            if force_market is None:
                if not self._is_closed_for_today(market):
                    continue
                if self._already_warmed(market, trading_date):
                    continue
            n, archived = self._warm_market(market, trading_date)
            self._mark_warmed(market, trading_date)
            warmed.append(market.value)
            # Roll the retention window after warming this market.
            purged = 0
            if self._archive is not None:
                try:
                    purged = self._archive.purge_old()
                except Exception:  # noqa: BLE001
                    pass
            self.last_warm[market.value] = {
                "trading_date": trading_date,
                "symbols": n,
                "archived": archived,
                "purged_days": purged,
                "at": time.time(),
            }
        return warmed

    # -- the gradual warm loop ---------------------------------------------
    def _warm_market(self, market: Market, trading_date: str) -> tuple:
        symbols = list(self._symbols_for(market) or [])
        if self._max_symbols and len(symbols) > self._max_symbols:
            symbols = symbols[: self._max_symbols]
        total = len(symbols)
        if total == 0:
            return (0, 0)
        logger.info(
            "warmer: warming %s (%d symbols, trading_date=%s, delay=%.2fs)",
            market.value, total, trading_date, self._delay,
        )
        ok = 0
        archived = 0
        for i, sym in enumerate(symbols):
            if self._stop.is_set():
                logger.info("warmer: %s interrupted at %d/%d", market.value, i, total)
                break
            try:
                df = self._fetch_symbol(sym, market)
                ok += 1
                if self._archive is not None and df is not None:
                    if self._archive.store(market.value, trading_date, sym, df):
                        archived += 1
            except Exception as exc:  # noqa: BLE001 — one bad symbol never stops the warm
                logger.debug("warmer: fetch failed %s/%s: %s", market.value, sym, exc)
            # Throttle between fetches (interruptible).
            if self._delay > 0 and i + 1 < total:
                self._stop.wait(self._delay)
        logger.info(
            "warmer: %s done — %d/%d warmed, %d archived (trading_date=%s)",
            market.value, ok, total, archived, trading_date,
        )
        return (ok, archived)
