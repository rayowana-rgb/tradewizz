"""FastAPI router for /v1/radar/* — Opportunity Radar, Daily Picks, Multibagger.

Gating (subscription):
  * /opportunities, /daily  -> PRO (FEATURE_OPPORTUNITY_RADAR / DAILY_PICKS)
  * /multibagger            -> ELITE (FEATURE_MULTIBAGGER)

Every successful view is recorded as a `radar_view` analytics event (Phase 9).
Research only: nothing here contacts a broker or places an order.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..subscription.entitlements import (
    FEATURE_DAILY_PICKS,
    FEATURE_MULTIBAGGER,
    FEATURE_OPPORTUNITY_RADAR,
)
from ..subscription.router import get_service as get_sub_service
from ..subscription.service import METRIC_RADAR_VIEW, SubscriptionError
from .models import (
    DailyPicksResponse,
    MultibaggerResponse,
    OpportunitiesResponse,
)
from .service import RadarService

router = APIRouter(prefix="/v1/radar", tags=["radar"])

_service: Optional[RadarService] = None


def set_service(service: RadarService) -> None:
    global _service
    _service = service


def get_service() -> RadarService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Radar not ready.")
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


@router.get("/opportunities", response_model=OpportunitiesResponse)
def opportunities(
    authorization: Optional[str] = Header(default=None),
) -> OpportunitiesResponse:
    uid = _user_id(authorization)
    _require(uid, FEATURE_OPPORTUNITY_RADAR)
    get_sub_service().record_usage(uid, METRIC_RADAR_VIEW, meta="opportunities")
    return get_service().opportunities()


@router.get("/daily", response_model=DailyPicksResponse)
def daily(
    authorization: Optional[str] = Header(default=None),
) -> DailyPicksResponse:
    uid = _user_id(authorization)
    _require(uid, FEATURE_DAILY_PICKS)
    get_sub_service().record_usage(uid, METRIC_RADAR_VIEW, meta="daily")
    return get_service().daily()


@router.get("/multibagger", response_model=MultibaggerResponse)
def multibagger(
    authorization: Optional[str] = Header(default=None),
) -> MultibaggerResponse:
    uid = _user_id(authorization)
    _require(uid, FEATURE_MULTIBAGGER)
    get_sub_service().record_usage(uid, METRIC_RADAR_VIEW, meta="multibagger")
    return get_service().multibagger()
