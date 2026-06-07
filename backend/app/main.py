"""TradeWiz backend API (FastAPI).

Skeleton that returns deterministic mock JSON matching the Flutter app's
models. Replace the `mock_*` calls with the real screening engine later.
"""

from __future__ import annotations

import logging
import os
from typing import List, Optional

from fastapi import FastAPI, HTTPException, Query
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
def analyze(symbol: str, market: Market = Market.IDX) -> AnalysisResult:
    """Full analysis for a single symbol (real engine, mock fallback)."""
    if not symbol.strip():
        raise HTTPException(status_code=400, detail="symbol is required")
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
