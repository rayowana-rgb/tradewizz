"""FastAPI router for /v1/morning-brief/{market} — the AI Morning Brief.

Open to all during the preview phase (no hard gate). Each view records a
`morning_brief_opened` demand event. Research only — no broker contact.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..models import Market
from ..subscription.router import get_service as get_sub_service
from ..subscription.service import EVENT_MORNING_BRIEF_OPENED
from .models import MorningBrief
from .service import MorningBriefService

router = APIRouter(prefix="/v1/morning-brief", tags=["morning-brief"])

_service: Optional[MorningBriefService] = None


def set_service(service: MorningBriefService) -> None:
    global _service
    _service = service


def get_service() -> MorningBriefService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Morning Brief not ready.")
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


def _parse_market(market: str) -> Market:
    try:
        return Market(market.upper())
    except ValueError:
        raise HTTPException(
            status_code=404, detail=f"Unknown market '{market}'."
        )


@router.get("/{market}", response_model=MorningBrief)
def morning_brief(
    market: str,
    authorization: Optional[str] = Header(default=None),
) -> MorningBrief:
    """The once-per-session AI Morning Brief for a market (open to all)."""
    uid = _user_id(authorization)
    mkt = _parse_market(market)
    sub = get_sub_service()
    # morning_brief_opened: user_id, market.
    sub.record_preview_event(uid, EVENT_MORNING_BRIEF_OPENED, meta=mkt.value)
    return get_service().brief(mkt)
