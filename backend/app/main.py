"""TradeWiz backend API (FastAPI).

Skeleton that returns deterministic mock JSON matching the Flutter app's
models. Replace the `mock_*` calls with the real screening engine later.
"""

from __future__ import annotations

import logging
import os
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
_sim_service = SimulationService(
    price_provider=lambda symbol, market: engine.latest_price(symbol, market),
    universe=engine._universe,
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

# Portfolio Health + Position Quality (Elite). Reads SIMULATED positions and
# the existing engine score per symbol.
from .portfolio_health.router import router as health_router  # noqa: E402
from .portfolio_health.router import (  # noqa: E402
    set_service as _set_health_service,
)
from .portfolio_health.service import PortfolioHealthService  # noqa: E402


def _symbol_score(symbol, market):
    """Single-symbol score via the existing engine (ScreenerMatch or None)."""
    try:
        result = engine.screen(market, symbols=[symbol], limit=1)
        return result.matches[0] if result.matches else None
    except Exception:  # noqa: BLE001
        return None


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
    regime_provider=_radar_service.market_regime,
)
app.include_router(rebalance_router)
_set_rebalance_service(_rebalance_service)

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
    MarketIndicesService,
    MarketOverviewService,
)

market_indices_service = MarketIndicesService()


def set_market_indices_service(service) -> None:
    """Test hook: swap the indices service (e.g. with a fake fetcher)."""
    global market_indices_service
    market_indices_service = service


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


def _category_cache_token(cats: Optional[List[ScreenerCategory]]) -> str:
    """Stable, order-independent category token for the screener cache key.

    Empty/None filter -> "" (the "all categories" snapshot).
    """
    if not cats:
        return ""
    return ",".join(sorted(c.value for c in cats))


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
    cache_key = make_cache_key(
        category=_category_cache_token(parsed_cats),
        limit=limit,
        min_score=min_score,
        min_value_traded=floor,
    )

    def _run() -> ScreenerResult:
        return engine.screen(
            parsed_market,
            limit=limit,
            min_score=min_score,
            categories=parsed_cats,
            min_value_traded=floor,
        )

    service = ScreenerCacheService(
        screener_snapshot_store,
        _run,
        now_provider=_screener_now_override,
    )
    return service.get(
        parsed_market, cache_key, force_refresh=force_refresh
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


# Background snapshot scheduler (Phase E). Disabled under pytest / when
# TRADEWIZZ_DISABLE_SCHEDULER is set so tests stay deterministic.
_snapshot_scheduler = SnapshotScheduler(_snapshot_service)

if not os.environ.get("TRADEWIZZ_DISABLE_SCHEDULER") and \
        not os.environ.get("PYTEST_CURRENT_TEST"):
    @app.on_event("startup")
    def _start_snapshot_scheduler() -> None:  # pragma: no cover
        _snapshot_scheduler.start()

    @app.on_event("shutdown")
    def _stop_snapshot_scheduler() -> None:  # pragma: no cover
        _snapshot_scheduler.stop()
