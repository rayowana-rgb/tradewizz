"""FastAPI router for /v1/portfolio (unified, auth-scoped)."""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from .models import (
    PortfolioPerformance,
    PortfolioSnapshot,
    UnifiedPortfolio,
)
from .performance import PerformanceService
from .service import PortfolioService

router = APIRouter(prefix="/v1/portfolio", tags=["portfolio"])

_service = PortfolioService()
_perf_service = PerformanceService(portfolio=_service)


def get_service() -> PortfolioService:
    return _service


def set_service(service: PortfolioService) -> None:
    global _service
    _service = service


def get_performance_service() -> PerformanceService:
    return _perf_service


def set_performance_service(service: PerformanceService) -> None:
    global _perf_service
    _perf_service = service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("", response_model=UnifiedPortfolio)
def portfolio(
    authorization: Optional[str] = Header(default=None),
) -> UnifiedPortfolio:
    uid = _user_id(authorization)
    return get_service().for_user(uid)


@router.get("/performance", response_model=PortfolioPerformance)
def performance(
    authorization: Optional[str] = Header(default=None),
) -> PortfolioPerformance:
    uid = _user_id(authorization)
    return get_performance_service().performance(uid)


@router.post("/snapshot", response_model=PortfolioSnapshot)
def snapshot(
    authorization: Optional[str] = Header(default=None),
) -> PortfolioSnapshot:
    uid = _user_id(authorization)
    return get_performance_service().create_snapshot(uid)
