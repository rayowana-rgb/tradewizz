"""FastAPI router for /v1/auto-watchlist — Auto Watchlist AI.

  * GET  /v1/auto-watchlist/suggestions  -> ranked daily suggestions
  * POST /v1/auto-watchlist/apply         -> apply selected/all suggestions
  * GET  /v1/auto-watchlist/settings      -> read per-user settings
  * POST /v1/auto-watchlist/settings      -> save per-user settings

Demand events: auto_watchlist_opened (suggestions), auto_watchlist_applied
(apply), auto_watchlist_ignored (apply with `ignored` items). Research only.
"""

from __future__ import annotations

from typing import List, Optional

from fastapi import APIRouter, Header, HTTPException, Query

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..subscription.router import get_service as get_sub_service
from ..subscription.service import (
    EVENT_AUTO_WATCHLIST_APPLIED,
    EVENT_AUTO_WATCHLIST_IGNORED,
    EVENT_AUTO_WATCHLIST_OPENED,
)
from .models import (
    ApplyRequest,
    ApplyResponse,
    AutoWatchlistSettings,
    AutoWatchlistSuggestionsResponse,
)
from .service import AutoWatchlistService

router = APIRouter(prefix="/v1/auto-watchlist", tags=["auto-watchlist"])

_service: Optional[AutoWatchlistService] = None


def set_service(service: AutoWatchlistService) -> None:
    global _service
    _service = service


def get_service() -> AutoWatchlistService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Auto Watchlist not ready.")
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("/suggestions", response_model=AutoWatchlistSuggestionsResponse)
def suggestions(
    existing: Optional[List[str]] = Query(default=None),
    authorization: Optional[str] = Header(default=None),
) -> AutoWatchlistSuggestionsResponse:
    """Ranked daily watchlist suggestions (excludes watchlist + owned)."""
    uid = _user_id(authorization)
    get_sub_service().record_preview_event(uid, EVENT_AUTO_WATCHLIST_OPENED)
    return get_service().suggestions(uid, existing=existing)


@router.post("/apply", response_model=ApplyResponse)
def apply(
    req: Optional[ApplyRequest] = None,
    authorization: Optional[str] = Header(default=None),
) -> ApplyResponse:
    """Apply selected suggestions (or all of today's when none given)."""
    uid = _user_id(authorization)
    items = req.items if req else None
    existing = req.existing if req else []
    applied, skipped = get_service().apply(uid, items=items, existing=existing)
    sub = get_sub_service()
    if applied:
        sub.record_preview_event(
            uid, EVENT_AUTO_WATCHLIST_APPLIED, count=len(applied)
        )
    if skipped:
        sub.record_preview_event(
            uid, EVENT_AUTO_WATCHLIST_IGNORED, count=len(skipped)
        )
    return ApplyResponse(
        applied=applied,
        skipped=skipped,
        count=len(applied),
    )


@router.get("/settings", response_model=AutoWatchlistSettings)
def get_settings(
    authorization: Optional[str] = Header(default=None),
) -> AutoWatchlistSettings:
    """Read the user's Auto Watchlist AI settings."""
    uid = _user_id(authorization)
    return get_service().get_settings(uid)


@router.post("/settings", response_model=AutoWatchlistSettings)
def save_settings(
    settings: AutoWatchlistSettings,
    authorization: Optional[str] = Header(default=None),
) -> AutoWatchlistSettings:
    """Persist the user's Auto Watchlist AI settings."""
    uid = _user_id(authorization)
    return get_service().save_settings(uid, settings)
