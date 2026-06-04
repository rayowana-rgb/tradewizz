"""TradeWiz backend API (FastAPI).

Skeleton that returns deterministic mock JSON matching the Flutter app's
models. Replace the `mock_*` calls with the real screening engine later.
"""

from __future__ import annotations

from typing import List, Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from .backtest import (
    DEFAULT_FORWARD_DAYS,
    DEFAULT_SIGNAL_TYPE,
    SIGNAL_TYPES,
)
from .engine import DEFAULT_LIMIT, MAX_LIMIT, AnalysisEngine
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
    allow_methods=["GET", "OPTIONS"],
    allow_headers=["*"],
)

# Real analysis engine (yfinance-backed, with mock fallback on failure).
engine = AnalysisEngine()


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


@app.get(f"{API_PREFIX}/screen/{{market}}", response_model=ScreenerResult)
def screen(
    market: str,
    limit: int = Query(DEFAULT_LIMIT, ge=1, le=MAX_LIMIT),
    min_score: float = Query(0.0, ge=0.0, le=100.0),
    categories: Optional[str] = Query(
        None, description="Comma-separated category filter, e.g. bullish,scalping"
    ),
) -> ScreenerResult:
    """Screener results for a market.

    Query params:
      - ``limit``: max matches (1..200, default 50).
      - ``min_score``: minimum score 0..100 (default 0).
      - ``categories``: comma-separated category filter (match must carry one).

    Results are sorted by score desc, then change_percent desc.
    """
    return engine.screen(
        _parse_market(market),
        limit=limit,
        min_score=min_score,
        categories=_parse_categories(categories),
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
