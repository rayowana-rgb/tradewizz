"""TradeWiz backend API (FastAPI).

Skeleton that returns deterministic mock JSON matching the Flutter app's
models. Replace the `mock_*` calls with the real screening engine later.
"""

from __future__ import annotations

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from . import mock_data
from .models import (
    AnalysisResult,
    HealthResponse,
    Market,
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
    """Full analysis for a single symbol."""
    if not symbol.strip():
        raise HTTPException(status_code=400, detail="symbol is required")
    return mock_data.mock_analyze(symbol, market)


@app.get(f"{API_PREFIX}/screen/{{market}}", response_model=ScreenerResult)
def screen(market: str) -> ScreenerResult:
    """Screener results for a market."""
    return mock_data.mock_screen(_parse_market(market))


@app.get(
    f"{API_PREFIX}/predict_weekly/{{symbol}}",
    response_model=WeeklyPrediction,
)
def predict_weekly(symbol: str) -> WeeklyPrediction:
    """Weekly prediction for a symbol."""
    if not symbol.strip():
        raise HTTPException(status_code=400, detail="symbol is required")
    return mock_data.mock_predict_weekly(symbol)
