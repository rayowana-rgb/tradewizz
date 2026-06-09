"""FastAPI router for /v1/portfolio/health + /v1/portfolio/quality (Elite).

Both endpoints are ELITE-only (FEATURE_PORTFOLIO_HEALTH / POSITION_QUALITY) and
analyze the user's SIMULATED portfolio. Each successful call is recorded as a
`portfolio_usage` analytics event. No broker contact, ever.

Note: these live under /v1/portfolio/* but are a NEW router, separate from the
existing broker-aggregated portfolio router; they only read simulated data.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..subscription.entitlements import (
    FEATURE_PORTFOLIO_HEALTH,
    FEATURE_POSITION_QUALITY,
)
from ..subscription.router import get_service as get_sub_service
from ..subscription.service import METRIC_PORTFOLIO, SubscriptionError
from .models import PortfolioHealth, PositionQualityResponse
from .service import PortfolioHealthService

router = APIRouter(prefix="/v1/portfolio", tags=["portfolio-health"])

_service: Optional[PortfolioHealthService] = None


def set_service(service: PortfolioHealthService) -> None:
    global _service
    _service = service


def get_service() -> PortfolioHealthService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Portfolio health not ready.")
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


def _require(uid: int, feature: str) -> None:
    try:
        get_sub_service().require_feature(uid, feature)
    except SubscriptionError as exc:
        raise HTTPException(
            status_code=exc.status_code,
            detail={"message": exc.message, **exc.extra},
        )


@router.get("/health", response_model=PortfolioHealth)
def portfolio_health(
    authorization: Optional[str] = Header(default=None),
) -> PortfolioHealth:
    uid = _user_id(authorization)
    _require(uid, FEATURE_PORTFOLIO_HEALTH)
    get_sub_service().record_usage(uid, METRIC_PORTFOLIO, meta="health")
    return get_service().health(uid)


@router.get("/quality", response_model=PositionQualityResponse)
def position_quality(
    authorization: Optional[str] = Header(default=None),
) -> PositionQualityResponse:
    uid = _user_id(authorization)
    _require(uid, FEATURE_POSITION_QUALITY)
    get_sub_service().record_usage(uid, METRIC_PORTFOLIO, meta="quality")
    return get_service().position_quality(uid)
