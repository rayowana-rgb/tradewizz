"""FastAPI router for /v1/journal — the Portfolio Journal + stats.

Open to all during the preview phase. Each list view records a `journal_opened`
demand event. Reads SIMULATED data only — no broker contact.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..subscription.router import get_service as get_sub_service
from ..subscription.service import EVENT_JOURNAL_OPENED
from .models import JournalList, JournalStats
from .service import JournalService

router = APIRouter(prefix="/v1/journal", tags=["journal"])

_service: Optional[JournalService] = None


def set_service(service: JournalService) -> None:
    global _service
    _service = service


def get_service() -> JournalService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Journal not ready.")
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("", response_model=JournalList)
def journal(
    authorization: Optional[str] = Header(default=None),
) -> JournalList:
    """The user's research journal entries (open to all during preview)."""
    uid = _user_id(authorization)
    get_sub_service().record_preview_event(uid, EVENT_JOURNAL_OPENED)
    return get_service().entries(uid)


@router.get("/stats", response_model=JournalStats)
def journal_stats(
    authorization: Optional[str] = Header(default=None),
) -> JournalStats:
    """Aggregate journal statistics (win rate, avg gain/loss, best/worst)."""
    uid = _user_id(authorization)
    return get_service().stats(uid)
