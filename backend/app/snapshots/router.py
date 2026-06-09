"""FastAPI router for /v1/snapshot/* — offline-first snapshots (Phase A/B/C).

  * GET /v1/snapshot/dashboard?market=US   -> one document for the dashboard.
  * GET /v1/snapshot/portfolio             -> account + positions + health/mgr.
  * GET /v1/snapshot/watchlist?market=US   -> watchlist AI + rotation + daily.

Each returns a pre-computed, server-cached document so the app makes ONE
request instead of 10–20. ``?force=true`` forces a rebuild (pull-to-refresh).
Research only — no broker contact.
"""

from __future__ import annotations

from typing import List, Optional

from fastapi import APIRouter, Header, HTTPException, Query

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..models import Market
from .models import DashboardSnapshot, PortfolioSnapshot, WatchlistSnapshot
from .service import SnapshotService

router = APIRouter(prefix="/v1/snapshot", tags=["snapshot"])

_service: Optional[SnapshotService] = None


def set_service(service: SnapshotService) -> None:
    global _service
    _service = service


def get_service() -> SnapshotService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Snapshots not ready.")
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


def _parse_market(market: Optional[str]) -> Market:
    code = (market or "US").upper()
    try:
        return Market(code)
    except ValueError:
        raise HTTPException(status_code=404, detail=f"Unknown market '{market}'.")


@router.get("/dashboard", response_model=DashboardSnapshot)
def dashboard(
    market: Optional[str] = Query(default="US"),
    force: bool = Query(default=False),
    authorization: Optional[str] = Header(default=None),
) -> DashboardSnapshot:
    """One snapshot for the whole dashboard (open during preview)."""
    _user_id(authorization)
    return get_service().dashboard(_parse_market(market), force=force)


@router.get("/portfolio", response_model=PortfolioSnapshot)
def portfolio(
    force: bool = Query(default=False),
    authorization: Optional[str] = Header(default=None),
) -> PortfolioSnapshot:
    """The user's SIMULATED portfolio snapshot."""
    uid = _user_id(authorization)
    return get_service().portfolio(uid, force=force)


@router.get("/watchlist", response_model=WatchlistSnapshot)
def watchlist(
    market: Optional[str] = Query(default="US"),
    existing: Optional[List[str]] = Query(default=None),
    force: bool = Query(default=False),
    authorization: Optional[str] = Header(default=None),
) -> WatchlistSnapshot:
    """Watchlist AI + rotation + daily picks in one document."""
    uid = _user_id(authorization)
    return get_service().watchlist(
        uid, _parse_market(market), existing=existing, force=force
    )
