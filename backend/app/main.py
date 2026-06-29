"""TradeWiz backend API (FastAPI).

Skeleton that returns deterministic mock JSON matching the Flutter app's
models. Replace the `mock_*` calls with the real screening engine later.
"""

from __future__ import annotations

import logging
import os
import threading
from typing import List, Optional

from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from .backtest import (
    DEFAULT_FORWARD_DAYS,
    DEFAULT_SIGNAL_TYPE,
    SIGNAL_TYPES,
)
from .engine import (
    DEFAULT_LIMIT,
    MAX_LIMIT,
    AnalysisEngine,
    default_min_value_traded,
    yf_symbol,
)
from .models import (
    AnalysisResult,
    BacktestResult,
    HealthResponse,
    Market,
    ScreenerCategory,
    ScreenerResult,
    WeeklyPrediction,
)

API_PREFIX = "/v1"
VERSION = "0.1.0"

logger = logging.getLogger("tradewizz.api")

app = FastAPI(
    title="TradeWiz Backend",
    version=VERSION,
    description="Stock screening & analysis API for the TradeWiz mobile app.",
)

# CORS: permissive for mobile/local development. Tighten allow_origins for prod.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

# Real analysis engine (yfinance-backed, with mock fallback on failure).
engine = AnalysisEngine()

# --- Global market expansion: market config + universe startup validation ---
from .market_config import MARKET_CONFIGS  # noqa: E402
from .universe_validation import (  # noqa: E402
    validate_universes,
    report_to_dict,
)

# Cached validation report (computed at startup; re-exposed via an endpoint).
_universe_validation_report = {}


@app.on_event("startup")
def _validate_universes_on_startup() -> None:
    """Verify every required market's Excel universe + config at startup.

    Logs a Market | Symbols | ETFs | Stocks table. Never raises (a bad/missing
    file just yields an empty universe + a FAIL row), so it cannot crash the
    API. IDX behavior is unchanged.
    """
    global _universe_validation_report
    try:
        report = validate_universes(engine._universe, log=True)
        _universe_validation_report = report_to_dict(report)
    except Exception as exc:  # noqa: BLE001 - validation must never crash boot
        logger.warning("Universe validation step failed: %s", exc)
        _universe_validation_report = {}

# Manual broker (Moomoo) endpoints under /v1/broker. Paper by default; every
# order requires explicit confirmation. Registered as a router so the existing
# analyze/screen/backtest contracts are untouched.
from .broker.router import router as broker_router  # noqa: E402

app.include_router(broker_router)

# User account / auth endpoints under /v1/auth (JWT + bcrypt). Registered as a
# router so existing analyze/screen/backtest/broker contracts are untouched.
from .auth.router import router as auth_router  # noqa: E402

app.include_router(auth_router)

# PRIVATE single-user Moomoo LIVE trading bridge under /v1/broker/moomoo.
# Hard-disabled unless TRADEWIZZ_MOOMOO_SECRET is set; gated by owner JWT
# allowlist + shared-secret header. NOT part of the public product surface.
from .moomoo.router import router as moomoo_router  # noqa: E402

app.include_router(moomoo_router)

# Per-user multi-broker connection framework under /v1/brokers.
from .brokers.router import router as brokers_router  # noqa: E402
from .brokers.router import get_service as _get_conn_service  # noqa: E402
from .auth.router import get_service as _get_auth_service  # noqa: E402

app.include_router(brokers_router)

# Report the real active-connection count in the user profile.
_get_auth_service().set_broker_count_provider(
    lambda user_id: _get_conn_service().count_active(user_id)
)

# Unified portfolio (aggregates across a user's connected brokers).
from .portfolio.router import router as portfolio_router  # noqa: E402

app.include_router(portfolio_router)

# Simulated paper-trading portfolio under /v1/sim. Broker-free: buy/sell are
# simulated against the existing fetch engine's latest price (price lookup
# only); NO broker connection, NO IBKR/Moomoo call. Every response is marked
# simulated=true with a clear disclaimer.
from .simulation.router import router as sim_router  # noqa: E402
from .simulation.router import set_service as _set_sim_service  # noqa: E402
from .simulation.service import SimulationService  # noqa: E402

app.include_router(sim_router)


def _sim_price(symbol, market):
    """Price source for simulated orders: cache-only first, never block.

    A simulated BUY/SELL is priced from the latest CACHED close so the order
    fills instantly. It only falls back to a (possibly slow) live fetch when
    nothing is cached for the symbol at all -- otherwise a slow/blocked data
    provider would stall or time out the order (preview + place each priced a
    symbol, so a cold fetch was paid twice). The warmer/screener keeps prices
    warm, so the fallback is rare.
    """
    cached = engine.latest_price_cached(symbol, market)
    if cached is not None:
        return cached
    return engine.latest_price(symbol, market)


def _sim_open_price(symbol, market, after_date):
    """OPEN price of the first cached bar after ``after_date`` (cache-only).

    Used to settle a simulated order queued while the market was closed: it
    fills at the next session's open once that bar is in the warmer-maintained
    cache. Returns (open_price, bar_date) or None.
    """
    return engine.open_after_cached(symbol, market, after_date)


_sim_service = SimulationService(
    price_provider=_sim_price,
    universe=engine._universe,
    open_price_provider=_sim_open_price,
)
_set_sim_service(_sim_service)

# --------------------------------------------------------------------------- #
# Monetization: subscriptions (FREE/PRO/ELITE), Opportunity Radar, Daily Picks,
# Multibagger Finder, Portfolio Health + Position Quality, and usage analytics.
# Research/AI/simulation only - NO broker integration, NO real-money trading.
# --------------------------------------------------------------------------- #
from .subscription.router import router as subscription_router  # noqa: E402
from .subscription.router import set_service as _set_sub_service  # noqa: E402
from .subscription.router import get_service as _get_sub_service  # noqa: E402
from .subscription.service import (  # noqa: E402
    METRIC_WATCHLIST,
    SubscriptionError,
    SubscriptionService,
)

app.include_router(subscription_router)
_subscription_service = SubscriptionService()
_set_sub_service(_subscription_service)

# AI Opportunity Radar / Daily Picks / Multibagger. Reuse the screener engine.
from .radar.router import router as radar_router  # noqa: E402
from .radar.router import set_service as _set_radar_service  # noqa: E402
from .radar.service import RadarService  # noqa: E402


def _radar_screen(market, limit=50, min_score=0.0, min_value_traded=0.0):
    """Screen a market for the radar via the market-close cache (real data)."""
    cache_key = make_cache_key(
        category="",
        limit=limit,
        min_score=min_score,
        min_value_traded=min_value_traded,
    )

    def _run() -> ScreenerResult:
        return engine.screen(
            market,
            limit=limit,
            min_score=min_score,
            categories=None,
            min_value_traded=min_value_traded,
        )

    service = ScreenerCacheService(
        screener_snapshot_store,
        _run,
        now_provider=_screener_now_override,
    )
    return service.get(market, cache_key)


app.include_router(radar_router)
_radar_service = RadarService(screen_provider=_radar_screen)
_set_radar_service(_radar_service)

# AI Morning Brief (Phase 2): a rule-based, once-per-session market summary.
# Reuses the Radar (screener + ranking + regime); no LLM, no broker contact.
from .morning_brief.router import router as morning_brief_router  # noqa: E402
from .morning_brief.router import (  # noqa: E402
    set_service as _set_brief_service,
)
from .morning_brief.service import MorningBriefService  # noqa: E402

app.include_router(morning_brief_router)
_brief_service = MorningBriefService(radar=_radar_service)
_set_brief_service(_brief_service)

# Global market news feed (yfinance-sourced; research only, no auth gate).
from .news.router import router as news_router  # noqa: E402
from .news.router import set_service as _set_news_service  # noqa: E402
from .news.service import NewsService  # noqa: E402

app.include_router(news_router)
_news_service = NewsService()
_set_news_service(_news_service)

# Portfolio Health + Position Quality (Elite). Reads SIMULATED positions and
# the existing engine score per symbol.
from .portfolio_health.router import router as health_router  # noqa: E402
from .portfolio_health.router import (  # noqa: E402
    set_service as _set_health_service,
)
from .portfolio_health.service import PortfolioHealthService  # noqa: E402


# --------------------------------------------------------------------------- #
# Per-market score index (snapshot-backed).                                    #
#                                                                              #
# Portfolio Health / Rebalance / Manager need a per-symbol score for every     #
# held position. Re-running ``engine.screen(symbols=[s])`` per symbol is        #
# O(positions) HEAVY work: each call can fetch/score a symbol (0.3-8s), so a    #
# 45-position portfolio took ~30s and blew past the app's 25s timeout.         #
#                                                                              #
# The market-close screener already scores the WHOLE universe and persists it  #
# as a snapshot (same one /screen serves). We read that snapshot ONCE per       #
# request-batch, build an in-memory {symbol -> ScreenerMatch} index, and serve  #
# per-symbol lookups in O(1). The snapshot is read-only here (we never trigger  #
# a heavy rebuild from this path), and the index is invalidated when the        #
# snapshot's generated_at changes. Symbols below the liquidity floor (not in    #
# the snapshot) fall back to a single-symbol screen.                           #
_score_index_lock = threading.Lock()
# market.value -> (generated_at_iso, {symbol: ScreenerMatch})
_score_index_cache: "dict[str, tuple[str, dict]]" = {}

# Short-TTL memo for per-symbol scores. Within one request, Rebalance scores
# every position TWICE (once via Portfolio Health, once via its own match
# lookup), and Health/Manager re-score the same names back-to-back. This memo
# collapses those repeats (and a 2nd call within the window) to O(1), which is
# the single biggest win for the slow single-symbol fallback path. Keyed by
# (market, symbol) -> (epoch, ScreenerMatch|None).
_SCORE_MEMO_TTL_S = 60.0
_score_memo_lock = threading.Lock()
_score_memo: "dict[tuple, tuple[float, object]]" = {}


def _score_memo_get(market_value, symbol):
    import time as _t
    with _score_memo_lock:
        hit = _score_memo.get((market_value, symbol))
        if hit is not None and (_t.time() - hit[0]) < _SCORE_MEMO_TTL_S:
            return True, hit[1]
    return False, None


def _score_memo_put(market_value, symbol, match):
    import time as _t
    with _score_memo_lock:
        _score_memo[(market_value, symbol)] = (_t.time(), match)


def invalidate_score_memo() -> None:
    """Clear the per-symbol score memo + snapshot index (tests / forced refresh)."""
    with _score_memo_lock:
        _score_memo.clear()
    with _score_index_lock:
        _score_index_cache.clear()


def _snapshot_score_index(market):
    """Return {symbol: ScreenerMatch} from today's cached superset snapshot.

    Read-only: does not run the heavy engine or save snapshots. Returns ``None``
    when no snapshot exists for today (cold start) so the caller can fall back.
    """
    try:
        floor = default_min_value_traded(market)
        cache_key = make_cache_key(
            category="",
            limit=MAX_LIMIT,
            min_score=0.0,
            min_value_traded=floor,
        )
        today = trading_date_str(market)
        rec = screener_snapshot_store.get_for_date(
            market.value, cache_key, today
        )
        if rec is None:
            return None
        with _score_index_lock:
            cached = _score_index_cache.get(market.value)
            if cached is not None and cached[0] == rec.generated_at:
                return cached[1]
        result = ScreenerResult.model_validate(rec.payload())
        index = {m.symbol: m for m in result.matches}
        with _score_index_lock:
            _score_index_cache[market.value] = (rec.generated_at, index)
        return index
    except Exception:  # noqa: BLE001
        return None


def _snapshot_regime(market):
    """Bull/neutral/bear regime read from the cached superset snapshot.

    The radar's ``market_regime`` runs its OWN limit=50 screen (a different
    cache key from /screen), which on a cold US universe triggers a full
    12k-symbol scan -- pushing Rebalance past the app's timeout. The regime is
    a breadth signal (advancers' share) we can derive directly from the cached
    superset snapshot's matches -- read-only, no heavy work. Falls back to the
    radar provider only when no snapshot exists (cold start).
    """
    index = _snapshot_score_index(market)
    if index:
        from .radar.service import _regime_from_breadth
        return _regime_from_breadth(list(index.values()))
    # No snapshot yet (e.g. cold start, or right after a backend restart while
    # the market is closed and the warmer hasn't rebuilt the screener snapshot).
    # NEVER fall back to the radar here: its market_regime() runs a full
    # universe screen which, on a cold US universe, scans ~12k symbols and
    # blocks the Rebalance request past the app timeout -- making the
    # Rebalancing AI card silently disappear. A neutral regime is the safe,
    # non-blocking default; breadth refines it once the snapshot exists.
    return "neutral"


def _symbol_score(symbol, market):
    """Per-symbol score (ScreenerMatch or None).

    Fast path: O(1) lookup from today's cached full-universe snapshot. Slow
    fallback: single-symbol engine screen (cold start, or a held name below the
    liquidity floor that the universe screen excludes).
    """
    hit, cached = _score_memo_get(market.value, symbol)
    if hit:
        return cached

    index = _snapshot_score_index(market)
    if index is not None:
        match = index.get(symbol)
        if match is not None:
            _score_memo_put(market.value, symbol, match)
            return match
        # Snapshot exists but the symbol isn't in it (below the liquidity
        # floor, delisted, or non-universe). Score from CACHED OHLCV only.
    # Cache-only scoring: NEVER make a live fetch from this latency-sensitive
    # path. A held name with no cached data returns None, and the calling
    # services already substitute a neutral score (50) for a missing match.
    # (Previously a last-resort live single-symbol screen here would, under a
    # rate-limited provider, block for seconds per uncached name AND degrade
    # to a wrong mock score -- the dominant cause of the Rebalance timeout for
    # ETF/thin-name US portfolios. The daily warmer keeps held universe names
    # cached; truly-uncached names are rare and not worth blocking the whole
    # request.)
    match = engine.score_symbol_cached(symbol, market)
    _score_memo_put(market.value, symbol, match)
    return match


app.include_router(health_router)
_health_service = PortfolioHealthService(
    positions_provider=_sim_service.positions,
    score_provider=_symbol_score,
)
_set_health_service(_health_service)

# --------------------------------------------------------------------------- #
# Phase 2 (Retention & differentiation): AI Portfolio Manager, Portfolio
# Journal, in-app Notifications, and community demand analytics. All rule-based
# (no LLM), reuse existing signals, and touch SIMULATED data only.
# --------------------------------------------------------------------------- #

# AI Portfolio Manager (highest priority): rule-based advisory over the sim.
from .portfolio_manager.router import (  # noqa: E402
    router as portfolio_manager_router,
    set_service as _set_pm_service,
)
from .portfolio_manager.service import (  # noqa: E402
    PortfolioManagerService,
)

# Portfolio Journal: snapshot on buy / close on sell (fed by a sim trade hook).
from .journal.router import (  # noqa: E402
    router as journal_router,
    set_service as _set_journal_service,
)
from .journal.service import JournalService  # noqa: E402
from .journal.store import SqliteJournalStore  # noqa: E402

_journal_store = SqliteJournalStore(
    os.environ.get("TRADEWIZZ_JOURNAL_DB_PATH")
)
_journal_service = JournalService(
    store=_journal_store,
    score_provider=_symbol_score,
    health_service=_health_service,
    radar_service=_radar_service,
)
app.include_router(journal_router)
_set_journal_service(_journal_service)

# Best-effort journal hook on simulated trades (does NOT alter accounting).
from .simulation.router import set_trade_hook as _set_sim_trade_hook  # noqa: E402
_set_sim_trade_hook(
    lambda uid, symbol, market, side, qty, price: _journal_service.on_trade(
        uid, symbol, market, side, qty, price
    )
)

# AI Portfolio Manager wiring (needs health + sim positions/account + journal
# score snapshots for the "score has fallen" rule).
def _journal_score_snapshots(user_id):
    """Map (symbol, market) -> entry score from OPEN journal entries."""
    snapshots = {}
    try:
        for e in _journal_store.list_entries(user_id):
            if e.status == "OPEN" and e.score > 0:
                snapshots[(e.symbol, e.market)] = e.score
    except Exception:  # noqa: BLE001
        return {}
    return snapshots


app.include_router(portfolio_manager_router)
_pm_service = PortfolioManagerService(
    health_service=_health_service,
    positions_provider=_sim_service.positions,
    account_provider=_sim_service.account,
    snapshot_provider=_journal_score_snapshots,
)
_set_pm_service(_pm_service)

# --------------------------------------------------------------------------- #
# Phase 3 (Auto Watchlist AI, Portfolio Rebalancing AI, Global Rotation Engine).
# All rule-based, reuse the existing Radar/Health/Sim pipelines, touch only
# SIMULATED data, and never contact a broker.
# --------------------------------------------------------------------------- #

# Auto Watchlist AI: rule-based daily watchlist suggestions from the Radar.
from .auto_watchlist.router import (  # noqa: E402
    router as auto_watchlist_router,
    set_service as _set_auto_watchlist_service,
)
from .auto_watchlist.service import AutoWatchlistService  # noqa: E402
from .auto_watchlist.store import SqliteAutoWatchlistStore  # noqa: E402

_auto_watchlist_service = AutoWatchlistService(
    radar=_radar_service,
    store=SqliteAutoWatchlistStore(
        os.environ.get("TRADEWIZZ_AUTO_WATCHLIST_DB_PATH")
    ),
    positions_provider=_sim_service.positions,
)
app.include_router(auto_watchlist_router)
_set_auto_watchlist_service(_auto_watchlist_service)

# Portfolio Rebalancing AI: ADD/HOLD/REDUCE/EXIT over the simulation.
from .rebalance.router import (  # noqa: E402
    router as rebalance_router,
    set_service as _set_rebalance_service,
)
from .rebalance.service import RebalanceService  # noqa: E402

_rebalance_service = RebalanceService(
    health_service=_health_service,
    positions_provider=_sim_service.positions,
    account_provider=_sim_service.account,
    score_provider=_symbol_score,
    regime_provider=_snapshot_regime,
)
app.include_router(rebalance_router)
_set_rebalance_service(_rebalance_service)

# Wire the PRIVATE Moomoo analytics bridge: Portfolio Health + Rebalancing AI
# over LIVE Moomoo holdings, reusing the SAME scoring engine + regime provider.
from .moomoo.analytics import MoomooAnalytics  # noqa: E402
from .moomoo.router import (  # noqa: E402
    get_service as _get_moomoo_service,
    set_analytics as _set_moomoo_analytics,
)

_set_moomoo_analytics(
    MoomooAnalytics(
        moomoo_service=_get_moomoo_service(),
        score_provider=_symbol_score,
        regime_provider=_snapshot_regime,
    )
)

# Server-managed stop-loss / take-profit monitor. Moomoo's OpenD SDK has no
# native bracket/OCO for stocks (and native STOP/LIMIT need whole shares,
# while $500/name US plans are often fractional), so we manage the bracket on
# the server: poll live prices and submit a MARKET sell when a level is hit.
# Runs ONLY when the bridge is configured (secret set) and never under pytest.
import threading as _sltp_threading  # noqa: E402
import time as _sltp_time  # noqa: E402
from .moomoo.router import get_sltp_monitor as _get_sltp_monitor  # noqa: E402

_sltp_stop = _sltp_threading.Event()
_sltp_thread = None  # type: ignore


def _sltp_loop() -> None:  # pragma: no cover - background thread
    interval = float(os.environ.get("TRADEWIZZ_MOOMOO_SLTP_INTERVAL", "20"))
    while not _sltp_stop.is_set():
        try:
            mon = _get_sltp_monitor()
            # Only do live work when there is something to watch, so an idle
            # bridge never touches OpenD on a timer.
            if mon.store.active():
                acted = mon.tick()
                if acted:
                    logger.warning("MOOMOO SLTP monitor fired: %s", acted)
        except Exception as exc:  # noqa: BLE001
            logger.warning("MOOMOO SLTP monitor tick error: %s", exc)
        _sltp_stop.wait(interval)


def _sltp_monitor_enabled() -> bool:
    if os.environ.get("PYTEST_CURRENT_TEST"):
        return False
    if not os.environ.get("TRADEWIZZ_MOOMOO_SECRET", ""):
        return False
    return os.environ.get("TRADEWIZZ_MOOMOO_SLTP_MONITOR", "1") in (
        "1", "true", "True"
    )


if _sltp_monitor_enabled():  # pragma: no cover
    @app.on_event("startup")
    def _start_sltp_monitor() -> None:
        global _sltp_thread
        _sltp_stop.clear()
        _sltp_thread = _sltp_threading.Thread(
            target=_sltp_loop, name="moomoo-sltp", daemon=True
        )
        _sltp_thread.start()
        logger.info("MOOMOO SLTP monitor started")

    @app.on_event("shutdown")
    def _stop_sltp_monitor() -> None:
        _sltp_stop.set()

# Global Rotation Engine: rank all markets by opportunity environment.
from .rotation.router import (  # noqa: E402
    router as rotation_router,
    set_service as _set_rotation_service,
)
from .rotation.service import GlobalRotationService  # noqa: E402

_rotation_service = GlobalRotationService(radar=_radar_service)
app.include_router(rotation_router)
_set_rotation_service(_rotation_service)

# In-app Notification Engine: generates from radar + portfolio health + the
# Phase 3 Auto Watchlist / Rebalance / Rotation services.
from .notifications.router import (  # noqa: E402
    router as notifications_router,
    set_service as _set_notifications_service,
)
from .notifications.service import NotificationService  # noqa: E402
from .notifications.store import SqliteNotificationStore  # noqa: E402

_notification_service = NotificationService(
    store=SqliteNotificationStore(
        os.environ.get("TRADEWIZZ_NOTIFICATIONS_DB_PATH")
    ),
    radar_service=_radar_service,
    health_service=_health_service,
    auto_watchlist_service=_auto_watchlist_service,
    rebalance_service=_rebalance_service,
    rotation_service=_rotation_service,
)
app.include_router(notifications_router)
_set_notifications_service(_notification_service)

# Community demand analytics (Most Requested Features).
from .analytics.router import router as analytics_router  # noqa: E402
app.include_router(analytics_router)

# System / cache monitoring (Phase F): GET /v1/system/cache. The shared cache
# manager is a process-wide singleton reused by Morning Brief, Global Rotation
# and Opportunity Radar, so the counters here reflect those caches directly.
from .system.router import router as system_router  # noqa: E402
app.include_router(system_router)


def _optional_user_id(authorization):
    """Resolve a user id from a Bearer token if present; else None.

    Lets /analyze + /screen stay anonymous-friendly while enforcing per-tier
    limits + recording analytics only for authenticated users.
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        return None
    token = authorization.split(" ", 1)[1].strip()
    try:
        return _get_auth_service().verify_token(token)
    except Exception:  # noqa: BLE001 - invalid token => treat as anonymous
        return None

# Market-close screener cache. Heavy screening runs once per market/category
# after market close; the saved snapshot is reused until the next close. This
# is a thin cache around the existing engine.screen() (scoring/indicators/
# Yahoo/analysis untouched).
from .screener_cache import (  # noqa: E402
    SqliteScreenerSnapshotStore,
)
from .screener_cache.service import (  # noqa: E402
    ScreenerCacheService,
    make_cache_key,
)

_SCREENER_CACHE_DB = os.environ.get(
    "TRADEWIZ_SCREENER_CACHE_DB",
    os.path.join(".cache", "screener_snapshots.db"),
)
screener_snapshot_store = SqliteScreenerSnapshotStore(_SCREENER_CACHE_DB)

# Dashboard market index quotes (^JKSE / ^HSI / ^KS11 / ^KQ11) via Yahoo, with
# a short in-memory cache (5 min). Independent of the screener snapshot cache
# and of the scoring/analysis engine.
from .market import (  # noqa: E402
    MarketConditionService,
    MarketIndicesService,
    MarketOverviewService,
)

market_indices_service = MarketIndicesService()
market_condition_service = MarketConditionService()


def set_market_indices_service(service) -> None:
    """Test hook: swap the indices service (e.g. with a fake fetcher)."""
    global market_indices_service
    market_indices_service = service


def set_market_condition_service(service) -> None:
    """Test hook: swap the market-condition service."""
    global market_condition_service
    market_condition_service = service


# Dashboard Market Overview (breadth / top mover / value traded / foreign flow).
# It aggregates the EXISTING screener universe snapshot through the market-close
# screener cache, so it reuses cached real data (fast, no mock) and has its own
# short in-memory cache on top.
def _overview_universe(market: Market) -> ScreenerResult:
    """Full-universe screen for a market, via the market-close cache.

    No liquidity floor and no category filter, so breadth/value cover the whole
    universe. Heavy screening only runs after market close (and once on cold
    start); otherwise the saved snapshot is reused.
    """
    cache_key = make_cache_key(
        category="",
        limit=MAX_LIMIT,
        min_score=0.0,
        min_value_traded=0.0,
    )

    def _run() -> ScreenerResult:
        return engine.screen(
            market,
            limit=MAX_LIMIT,
            min_score=0.0,
            categories=None,
            min_value_traded=0.0,
        )

    service = ScreenerCacheService(
        screener_snapshot_store,
        _run,
        now_provider=_screener_now_override,
    )
    return service.get(market, cache_key)


market_overview_service = MarketOverviewService(_overview_universe)


def set_market_overview_service(service) -> None:
    """Test hook: swap the overview service (e.g. with a fake universe)."""
    global market_overview_service
    market_overview_service = service


# Wire market breadth into the Fear/Greed condition so it reflects how broadly
# stocks are advancing/declining (not just the headline index). Late-binding
# closure reads the module-global overview service so test hooks that swap it
# are honoured. Best-effort: the condition service swallows any error here and
# falls back to a price-only reading.
def _condition_breadth_provider(market: Market):
    ov = market_overview_service.get(market)
    if ov is None or not getattr(ov, "available", False):
        return (None, None)
    return (ov.advances, ov.declines)


market_condition_service._breadth_provider = _condition_breadth_provider

# Optional test hook: override the market-local "now" used by the screener
# cache so tests can pin OPEN/CLOSED deterministically. None => real clock.
_screener_now_override = None  # type: Optional[object]


def set_screener_now_override(provider) -> None:
    """Test hook: set a callable(Market)->datetime, or None to reset."""
    global _screener_now_override
    _screener_now_override = provider


def _parse_market(market: str) -> Market:
    try:
        return Market(market.upper())
    except ValueError as exc:
        supported = ", ".join(m.value for m in Market)
        raise HTTPException(
            status_code=404,
            detail=f"Unknown market '{market}'. Supported: {supported}.",
        ) from exc


@app.get(f"{API_PREFIX}/health", response_model=HealthResponse)
def health() -> HealthResponse:
    """Liveness check."""
    return HealthResponse(version=VERSION)


@app.get(f"{API_PREFIX}/market/indices")
def market_indices() -> dict:
    """Latest index quote for each supported market (Dashboard).

    Returns the correct Yahoo index per market (^JKSE / ^HSI / ^KS11 / ^KQ11)
    with price/change/change_percent/status/updated_at, cached ~5 minutes. On a
    data-source failure the affected index reports `available=false` with null
    numbers (never fabricated values), so the app can warn instead of showing
    wrong data.
    """
    quotes = market_indices_service.get_indices()
    return {"indices": [q.to_dict() for q in quotes]}


@app.get(f"{API_PREFIX}/market/condition")
def market_condition(market: Market) -> dict:
    """Phase E: rule-based Fear/Greed condition for one market's index.

    Returns ``{condition, condition_score, reason}`` derived purely from the
    index's recent price action (trend vs moving averages, 20-day return,
    distance from high/low, volatility, RSI). No LLM. Missing data -> a neutral
    ``UNKNOWN`` condition (never crashes).
    """
    cond = market_condition_service.get(market)
    out = cond.to_dict()
    out["market"] = market.value
    return out


@app.get(f"{API_PREFIX}/market/config")
def market_config_table() -> dict:
    """Per-market configuration (timezone/currency/yahoo_suffix/hours/name).

    Static metadata for the Dashboard/Screener market selectors. Read-only.
    """
    return {
        "markets": [cfg.to_dict() for cfg in MARKET_CONFIGS.values()],
    }


@app.get(f"{API_PREFIX}/market/universe/validate")
def market_universe_validate() -> dict:
    """Universe validation report (symbol/ETF/stock counts, duplicates, config).

    Returns the report computed at startup; recomputes on demand if empty.
    """
    global _universe_validation_report
    if not _universe_validation_report:
        _universe_validation_report = report_to_dict(
            validate_universes(engine._universe, log=False)
        )
    return {"validation": _universe_validation_report}


@app.get(f"{API_PREFIX}/market/overview/{{market}}")
def market_overview(market: str) -> dict:
    """Dashboard Market Overview for a market.

    Aggregated from the existing screener universe snapshot (real data, no
    mock): breadth (advances/declines/unchanged), top gainer, top loser, total
    value traded, and (IDX only) foreign flow. Cached ~5 minutes on top of the
    market-close screener cache, so it loads fast. On failure it reports
    `available=false` with null aggregates instead of fabricated values.
    """
    parsed_market = _parse_market(market)
    return market_overview_service.get(parsed_market).to_dict()


@app.get(f"{API_PREFIX}/analyze/{{symbol}}", response_model=AnalysisResult)
def analyze(
    symbol: str,
    market: Market = Market.IDX,
    authorization: Optional[str] = Header(default=None),
) -> AnalysisResult:
    """Full analysis for a single symbol (real engine, mock fallback).

    Anonymous callers are unmetered (back-compat). For an authenticated user
    the per-tier daily-analysis limit is enforced (FREE = 5/day) and the use is
    recorded for analytics; PRO/ELITE are unlimited.
    """
    if not symbol.strip():
        raise HTTPException(status_code=400, detail="symbol is required")
    uid = _optional_user_id(authorization)
    if uid is not None:
        try:
            _get_sub_service().check_and_count_analysis(uid)
        except SubscriptionError as exc:
            raise HTTPException(
                status_code=exc.status_code,
                detail={"message": exc.message, **exc.extra},
            )
    # Diagnostics: make the symbol+market -> Yahoo-ticker routing observable so
    # an HKEX request can never be silently mistaken for IDX (e.g. .JK vs .HK).
    logger.info(
        "analyze symbol=%s market=%s yahoo=%s",
        symbol, market.value, yf_symbol(symbol, market),
    )
    return engine.analyze(symbol, market)


def _parse_categories(raw: Optional[str]) -> Optional[List[ScreenerCategory]]:
    """Parse a comma-separated category filter; unknown values are ignored."""
    if not raw:
        return None
    out: List[ScreenerCategory] = []
    for part in raw.split(","):
        name = part.strip().lower()
        if not name:
            continue
        try:
            out.append(ScreenerCategory(name))
        except ValueError:
            continue  # silently drop unknown category names
    return out or None


def _slice_screener_result(
    result: ScreenerResult,
    *,
    limit: int,
    min_score: float,
    categories: Optional[List[ScreenerCategory]] = None,
) -> ScreenerResult:
    """Lapis 3: derive a per-request view from a SUPERSET snapshot in memory.

    The engine is cached at the superset (limit=MAX_LIMIT, min_score=0,
    categories=None), so a request only varies the heavy run by
    ``min_value_traded`` (the liquidity floor, which the engine applies during
    the run). The user's ``min_score``, ``categories``, and ``limit`` are all
    applied here with NO engine work, so many param variants (limit=20/50/100,
    min_score=0/60/70, any category filter) collapse onto a single cached run.

    Why category is sliced here, not keyed: the engine computes EVERY category
    in one pass and tags each match with its ``categories``; the category
    filter is a pure post-filter (``wanted.intersection(m.categories)``). Keying
    by category therefore forced a full, multi-second engine re-run the first
    time each category was opened in Explore -- which, when it exceeded the
    app's 25s request timeout, made the app fall back to MOCK screener data
    ("not the latest close"). Slicing categories from the shared ``_all``
    superset removes that per-category cold path entirely.

    Matches in the snapshot are already sorted (Final Explore Score desc,
    value_traded desc, change_percent desc) and already past the liquidity
    floor, so we only drop rows below ``min_score`` (on the Base Score, per the
    engine's documented semantics) and outside ``categories``, then truncate.
    Metadata is recomputed so ``total_count``/``returned_count``/``limit``/
    ``min_score``/``categories`` stay correct; cache/market metadata is kept.
    """
    limit = max(1, min(int(limit), MAX_LIMIT))
    wanted = set(categories or [])
    kept = [
        m
        for m in result.matches
        if m.score >= min_score
        and (not wanted or wanted.intersection(m.categories))
    ]
    view = result.model_copy(deep=True)
    view.total_count = len(kept)  # filtered count BEFORE the limit
    view.matches = kept[:limit]
    view.returned_count = len(view.matches)
    view.limit = limit
    view.min_score = min_score
    view.categories = list(categories or [])
    return view


@app.get(f"{API_PREFIX}/screen/{{market}}", response_model=ScreenerResult)
def screen(
    market: str,
    limit: int = Query(DEFAULT_LIMIT, ge=1, le=MAX_LIMIT),
    min_score: float = Query(0.0, ge=0.0, le=100.0),
    categories: Optional[str] = Query(
        None, description="Comma-separated category filter, e.g. bullish,scalping"
    ),
    min_value_traded: Optional[float] = Query(
        None,
        ge=0.0,
        description="Liquidity floor (turnover) in market currency. Omit for the "
        "per-market default (~2B IDR); pass 0 to disable.",
    ),
    force_refresh: bool = Query(
        False,
        description="Re-run heavy screening and save a fresh snapshot. Allowed "
        "only when the market is CLOSED; ignored (with a warning) when OPEN.",
    ),
    authorization: Optional[str] = Header(default=None),
) -> ScreenerResult:
    """Screener results for a market (market-close cached).

    Heavy screening runs once per market/category/params after market close;
    the saved snapshot is then reused until the next market close. While the
    market is OPEN the latest saved snapshot is served (``cached=true``) and no
    heavy screening runs, so reopening the app stays fast.

    Query params:
      - ``limit``: max matches (1..200, default 50).
      - ``min_score``: minimum score 0..100 (default 0).
      - ``categories``: comma-separated category filter (match must carry one).
      - ``min_value_traded``: liquidity floor; omitted => per-market default,
        0 => disabled.
      - ``force_refresh``: re-run + save once (CLOSED only; OPEN -> warning).

    Response metadata: ``cached``, ``generated_at``, ``market_date``,
    ``market_status``, ``next_refresh_rule`` (and ``warning`` when relevant).

    Results are sorted by score desc, value_traded desc (liquidity tiebreaker),
    then change_percent desc.
    """
    parsed_market = _parse_market(market)
    # Per-tier screener cap: FREE sees at most 20 results; PRO/ELITE unlimited.
    # Anonymous callers keep the requested limit (back-compat).
    uid = _optional_user_id(authorization)
    if uid is not None:
        limit = _get_sub_service().cap_screener_limit(uid, limit)
    floor = (
        default_min_value_traded(parsed_market)
        if min_value_traded is None
        else min_value_traded
    )
    parsed_cats = _parse_categories(categories)
    # Lapis 3: cache the engine at the SUPERSET (limit=MAX_LIMIT, min_score=0,
    # categories=None) so ONLY the liquidity floor (min_value_traded) varies the
    # heavy run. The user's limit/min_score/categories are applied in memory
    # afterwards, collapsing every param + category variant onto a single cached
    # run. (Category is a pure post-filter in the engine, so re-running per
    # category was wasted work that could exceed the app's timeout and trigger a
    # mock-data fallback in Explore.)
    cache_key = make_cache_key(
        category="",
        limit=MAX_LIMIT,
        min_score=0.0,
        min_value_traded=floor,
    )

    def _run() -> ScreenerResult:
        return engine.screen(
            parsed_market,
            limit=MAX_LIMIT,
            min_score=0.0,
            categories=None,
            min_value_traded=floor,
        )

    service = ScreenerCacheService(
        screener_snapshot_store,
        _run,
        now_provider=_screener_now_override,
    )
    superset = service.get(
        parsed_market, cache_key, force_refresh=force_refresh
    )
    # Apply the per-request view (tier cap already folded into ``limit``).
    return _slice_screener_result(
        superset, limit=limit, min_score=min_score, categories=parsed_cats
    )


@app.get(
    f"{API_PREFIX}/predict_weekly/{{symbol}}",
    response_model=WeeklyPrediction,
)
def predict_weekly(
    symbol: str, market: Market = Market.IDX
) -> WeeklyPrediction:
    """Weekly prediction for a symbol (real engine, mock fallback)."""
    if not symbol.strip():
        raise HTTPException(status_code=400, detail="symbol is required")
    logger.info(
        "predict_weekly symbol=%s market=%s yahoo=%s",
        symbol, market.value, yf_symbol(symbol, market),
    )
    return engine.predict_weekly(symbol, market)


@app.get(f"{API_PREFIX}/backtest/{{symbol}}", response_model=BacktestResult)
def backtest(
    symbol: str,
    market: Market = Market.IDX,
    signal_type: str = Query(
        DEFAULT_SIGNAL_TYPE,
        description="momentum | scalping | accumulation",
    ),
    forward_days: int = Query(DEFAULT_FORWARD_DAYS, ge=1, le=30),
) -> BacktestResult:
    """Backtest a historical buy-signal rule over the symbol's history.

    Returns win_rate, average_return, profit_factor, max_drawdown, and
    total_signals/total_wins/total_losses. Empty (zeroed) when no data.
    """
    if not symbol.strip():
        raise HTTPException(status_code=400, detail="symbol is required")
    if signal_type not in SIGNAL_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"signal_type must be one of {sorted(SIGNAL_TYPES)}",
        )
    return engine.backtest(symbol, market, signal_type, forward_days)


# --------------------------------------------------------------------------- #
# Cache diagnostics / control (trading-day-aware invalidation)                 #
# --------------------------------------------------------------------------- #
from .cache import all_caches  # noqa: E402
from .market_session import (  # noqa: E402
    get_market_session_state,
    trading_date_str,
)


@app.get(f"{API_PREFIX}/debug/cache")
def debug_cache() -> dict:
    """Inspect every OHLCV cache entry: key, age, symbol, market, latest candle.

    Read-only. Useful to confirm a stale entry was invalidated after market
    close / on a new trading day.
    """
    entries: List[dict] = []
    for cache in all_caches():
        try:
            entries.extend(cache.entries())
        except Exception as exc:  # noqa: BLE001
            logger.warning("debug_cache: failed to read a cache: %s", exc)
    entries.sort(key=lambda e: e.get("age_seconds", 0))
    sessions = {
        m.value: {
            "session_state": get_market_session_state(m).value,
            "trading_date": trading_date_str(m),
        }
        for m in Market
    }
    return {
        "count": len(entries),
        "entries": entries,
        "markets": sessions,
    }


@app.post(f"{API_PREFIX}/debug/cache/clear")
def debug_cache_clear(
    mode: str = Query("all", description="all | symbol | market"),
    symbol: Optional[str] = Query(None),
    market: Optional[str] = Query(None),
) -> dict:
    """Clear OHLCV cache entries. Modes: all | symbol | market.

    * all    -> remove every cached entry.
    * symbol -> require ``symbol`` (e.g. BBCA or BBCA.JK).
    * market -> require ``market`` (IDX | HKEX | KOSPI | KOSDAQ | US).
    """
    mode = (mode or "all").lower().strip()
    if mode == "symbol" and not (symbol and symbol.strip()):
        raise HTTPException(
            status_code=400, detail="mode=symbol requires ?symbol="
        )
    if mode == "market" and not (market and market.strip()):
        raise HTTPException(
            status_code=400, detail="mode=market requires ?market="
        )
    if mode not in ("all", "symbol", "market"):
        raise HTTPException(
            status_code=400, detail="mode must be all | symbol | market"
        )

    removed = 0
    for cache in all_caches():
        try:
            if mode == "all":
                removed += cache.clear()
            elif mode == "symbol":
                removed += cache.clear(symbol=symbol)
            else:
                removed += cache.clear(market=market)
        except Exception as exc:  # noqa: BLE001
            logger.warning("debug_cache_clear: failed on a cache: %s", exc)
    logger.info(
        "cache cleared mode=%s symbol=%s market=%s removed=%d",
        mode, symbol, market, removed,
    )
    return {"mode": mode, "symbol": symbol, "market": market,
            "removed": removed}


# --------------------------------------------------------------------------- #
# Phase 6 (Offline-first): Snapshot engine. Aggregates the OUTPUT of the
# existing services into pre-computed, server-cached documents so the app makes
# ONE request per surface instead of 10-20. No scoring/ranking/accounting lives
# here — it only calls the services above and serializes their results.
# --------------------------------------------------------------------------- #
from .snapshots.router import (  # noqa: E402
    router as snapshot_router,
    set_service as _set_snapshot_service,
)
from .snapshots.service import SnapshotService  # noqa: E402
from .snapshots.scheduler import SnapshotScheduler  # noqa: E402


def _notifications_list(uid: int):
    """(items, unread) tuple, mirroring the notifications endpoint."""
    return _notification_service.list(uid)


_snapshot_service = SnapshotService(
    indices_provider=lambda: [q.to_dict() for q in
                              market_indices_service.get_indices()],
    brief_provider=_brief_service.brief,
    rotation_provider=_rotation_service.global_rotation,
    opportunities_provider=_radar_service.opportunities,
    daily_provider=_radar_service.daily,
    multibagger_provider=_radar_service.multibagger,
    watchlist_provider=lambda uid, existing:
        _auto_watchlist_service.suggestions(uid, existing=existing),
    notifications_provider=_notifications_list,
    account_provider=_sim_service.account,
    positions_provider=_sim_service.positions,
    health_provider=_health_service.health,
    quality_provider=_health_service.position_quality,
    manager_provider=_pm_service.report,
)
app.include_router(snapshot_router)
_set_snapshot_service(_snapshot_service)


def set_snapshot_service(service) -> None:
    """Test hook: swap the snapshot service."""
    global _snapshot_service
    _snapshot_service = service
    _set_snapshot_service(service)


# Phase 7 (Global Snapshot CDN): publish generated snapshots to object storage
# (Cloudflare R2 by default, AWS S3 supported) so every user consumes the SAME
# snapshot from the edge. Publishing happens ONLY in the scheduler below —
# never on a user request. No scoring/ranking/accounting lives here.
from .cdn import SnapshotPublisher, build_storage_from_env  # noqa: E402
from .cdn.models import MARKETS as _CDN_MARKETS  # noqa: E402

_cdn_storage = build_storage_from_env()
_snapshot_publisher = SnapshotPublisher(
    _snapshot_service, _cdn_storage, markets=list(_CDN_MARKETS)
)


def set_snapshot_publisher(publisher) -> None:
    """Test hook: swap the CDN publisher."""
    global _snapshot_publisher
    _snapshot_publisher = publisher
    _snapshot_scheduler._publisher = publisher  # noqa: SLF001


# Background snapshot scheduler (Phase E). Disabled under pytest / when
# TRADEWIZZ_DISABLE_SCHEDULER is set so tests stay deterministic.
_snapshot_scheduler = SnapshotScheduler(
    _snapshot_service,
    publisher=_snapshot_publisher,
    invalidate_cdn=bool(os.environ.get("TRADEWIZZ_CDN_INVALIDATE")),
)

if not os.environ.get("TRADEWIZZ_DISABLE_SCHEDULER") and \
        not os.environ.get("PYTEST_CURRENT_TEST"):
    @app.on_event("startup")
    def _start_snapshot_scheduler() -> None:  # pragma: no cover
        _snapshot_scheduler.start()

    @app.on_event("shutdown")
    def _stop_snapshot_scheduler() -> None:  # pragma: no cover
        _snapshot_scheduler.stop()


# ---------------------------------------------------------------------------
# Daily OHLCV cache warmer (opt-in). After each market closes for the day, this
# gradually pre-fetches that market's universe OHLCV into the SAME on-disk cache
# the screener/analyze already read from, so screener results are served from
# warm cache. It only pre-warms data; it never changes scoring/engine behaviour.
# Disabled unless TRADEWIZZ_ENABLE_DAILY_WARMER is truthy (and never under
# pytest). Markets close at different local times, handled per-market inside.
from .screener_cache.warmer import DailyCacheWarmer, warmer_enabled  # noqa: E402


def _warm_fetch_symbol(symbol, market):
    """Fetch one symbol into the engine's OHLCV cache (same path as analyze).

    Returns the OHLCV DataFrame so the warmer can also archive it day-by-day.
    """
    ticker = yf_symbol(symbol, market)
    return engine._fetch(ticker, "1y", "1d")  # noqa: SLF001 — pre-warm shared cache


def _prewarm_default_screener(market: Market, trading_date: str) -> None:
    """Lapis 2: pre-compute + persist the DEFAULT screener snapshot post-warm.

    Runs the heavy engine ONCE for the default (anonymous) parameter set right
    after a market's OHLCV cache is warmed, and saves the snapshot. This turns
    the first real user request into a cache HIT instead of a cold-start engine
    run. Uses the same SUPERSET cache key the public /screen endpoint now reads
    (Lapis 3: limit=MAX_LIMIT, min_score=0; only category + floor vary the
    run), and force_refresh=True so it always runs+saves once (the warmer only
    fires after close, so CLOSED is satisfied).
    """
    floor = default_min_value_traded(market)
    cache_key = make_cache_key(
        category="",
        limit=MAX_LIMIT,
        min_score=0.0,
        min_value_traded=floor,
    )

    def _run() -> ScreenerResult:
        return engine.screen(
            market,
            limit=MAX_LIMIT,
            min_score=0.0,
            categories=None,
            min_value_traded=floor,
        )

    service = ScreenerCacheService(
        screener_snapshot_store,
        _run,
        now_provider=_screener_now_override,
    )
    service.get(market, cache_key, force_refresh=True)
    logger.info(
        "warmer: pre-warmed default screener snapshot for %s (%s)",
        market.value, trading_date,
    )


_cache_warmer = DailyCacheWarmer(
    fetch_symbol=_warm_fetch_symbol,
    symbols_for=lambda mk: engine._universe.symbols(mk),  # noqa: SLF001
    on_warmed=_prewarm_default_screener,
)

if warmer_enabled():  # pragma: no cover
    @app.on_event("startup")
    def _start_cache_warmer() -> None:
        _cache_warmer.start()

    @app.on_event("shutdown")
    def _stop_cache_warmer() -> None:
        _cache_warmer.stop()


@app.get(f"{API_PREFIX}/debug/warmer")
def debug_warmer() -> dict:
    """Inspect the daily OHLCV cache warmer (read-only).

    Shows whether it is enabled, its per-market close/trading-date state, and
    the last warm summary per market.
    """
    return {
        "enabled": warmer_enabled(),
        "delay_seconds": _cache_warmer._delay,  # noqa: SLF001
        "markets": [m.value for m in _cache_warmer._markets],  # noqa: SLF001
        "last_warm": _cache_warmer.last_warm,
        "archive": _cache_warmer._archive.summary()  # noqa: SLF001
        if _cache_warmer._archive is not None else None,  # noqa: SLF001
        "sessions": {
            m.value: {
                "session_state": get_market_session_state(m).value,
                "trading_date": trading_date_str(m),
            }
            for m in Market
        },
    }
