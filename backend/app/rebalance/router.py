"""FastAPI router for /v1/portfolio/rebalance — Portfolio Rebalancing AI.

  * GET /v1/portfolio/rebalance -> ADD/HOLD/REDUCE/EXIT actions over the sim.

Demand event: rebalance_opened. All buy/sell follow-through uses the simulation
order ticket only. Research only — no broker contact, no accounting here.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Query

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..subscription.router import get_service as get_sub_service
from ..subscription.service import EVENT_REBALANCE_OPENED
from .models import RebalanceResponse
from .service import RebalanceService

router = APIRouter(prefix="/v1/portfolio", tags=["rebalance"])

_service: Optional[RebalanceService] = None


def set_service(service: RebalanceService) -> None:
    global _service
    _service = service


def get_service() -> RebalanceService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Rebalance not ready.")
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("/rebalance", response_model=RebalanceResponse)
def rebalance(
    profile: Optional[str] = Query(default=None),
    authorization: Optional[str] = Header(default=None),
) -> RebalanceResponse:
    """Rule-based ADD/HOLD/REDUCE/EXIT suggestions over the simulation."""
    uid = _user_id(authorization)
    get_sub_service().record_preview_event(uid, EVENT_REBALANCE_OPENED)
    return get_service().rebalance(uid, profile=profile)
