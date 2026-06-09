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
from ..subscription.service import (
    EVENT_DAILY_PICKS_OPENED,
    EVENT_MULTIBAGGER_OPENED,
    EVENT_RADAR_OPENED,
    METRIC_RADAR_VIEW,
    SubscriptionError,
)
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
    market: Optional[str] = None,
    authorization: Optional[str] = Header(default=None),
) -> OpportunitiesResponse:
    """Opportunity Radar (PRO PREVIEW — open to all during the preview phase)."""
    uid = _user_id(authorization)
    _require(uid, FEATURE_OPPORTUNITY_RADAR)
    sub = get_sub_service()
    sub.record_usage(uid, METRIC_RADAR_VIEW, meta="opportunities")
    # radar_opened: user_id, market, timestamp (timestamp recorded by store).
    sub.record_preview_event(uid, EVENT_RADAR_OPENED, meta=market or "global")
    return get_service().opportunities()


@router.get("/daily", response_model=DailyPicksResponse)
def daily(
    authorization: Optional[str] = Header(default=None),
) -> DailyPicksResponse:
    """Daily Picks (PRO PREVIEW — open to all during the preview phase)."""
    uid = _user_id(authorization)
    _require(uid, FEATURE_DAILY_PICKS)
    sub = get_sub_service()
    sub.record_usage(uid, METRIC_RADAR_VIEW, meta="daily")
    # daily_picks_opened: user_id, timestamp.
    sub.record_preview_event(uid, EVENT_DAILY_PICKS_OPENED)
    return get_service().daily()


@router.get("/multibagger", response_model=MultibaggerResponse)
def multibagger(
    market: Optional[str] = None,
    authorization: Optional[str] = Header(default=None),
) -> MultibaggerResponse:
    """Multibagger Finder (ELITE PREVIEW — open to all during preview)."""
    uid = _user_id(authorization)
    _require(uid, FEATURE_MULTIBAGGER)
    sub = get_sub_service()
    sub.record_usage(uid, METRIC_RADAR_VIEW, meta="multibagger")
    # multibagger_opened: user_id, market.
    sub.record_preview_event(
        uid, EVENT_MULTIBAGGER_OPENED, meta=market or "all"
    )
    return get_service().multibagger()
