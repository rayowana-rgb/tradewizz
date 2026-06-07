"""TradeWiz backend API (FastAPI).

Skeleton that returns deterministic mock JSON matching the Flutter app's
models. Replace the `mock_*` calls with the real screening engine later.
"""

from __future__ import annotations

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


@app.get(f"{API_PREFIX}/analyze/{{symbol}}", response_model=AnalysisResult)
def analyze(symbol: str, market: Market = Market.IDX) -> AnalysisResult:
    """Full analysis for a single symbol (real engine, mock fallback)."""
    if not symbol.strip():
        raise HTTPException(status_code=400, detail="symbol is required")
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
