"""FastAPI router for /v1/analytics/demand — Most Requested Features.

Aggregates the preview-demand events (recorded across all Phase-2 features) into
a ranked "Most Requested Features" list, e.g.:

    AI Portfolio Manager: 532 opens
    Multibagger Finder:   420 opens
    Portfolio Health:     301 opens
    Daily Picks:          280 opens

Reuses the subscription demand breakdown; no new storage. Requires a valid
Bearer token (internal signal).
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..subscription.router import get_service as get_sub_service
from ..subscription.service import (
    EVENT_AI_PORTFOLIO_MANAGER_OPENED,
    EVENT_DAILY_PICKS_OPENED,
    EVENT_JOURNAL_OPENED,
    EVENT_MORNING_BRIEF_OPENED,
    EVENT_MULTIBAGGER_OPENED,
    EVENT_NOTIFICATION_OPENED,
    EVENT_PORTFOLIO_HEALTH_OPENED,
    EVENT_PORTFOLIO_MANAGER_OPENED,
    EVENT_PORTFOLIO_QUALITY_OPENED,
    EVENT_RADAR_OPENED,
)

router = APIRouter(prefix="/v1/analytics", tags=["analytics"])

# Map event names -> human feature labels for the demand dashboard.
_FEATURE_LABELS = {
    EVENT_AI_PORTFOLIO_MANAGER_OPENED: "AI Portfolio Manager",
    EVENT_PORTFOLIO_MANAGER_OPENED: "AI Portfolio Manager",
    EVENT_MULTIBAGGER_OPENED: "Multibagger Finder",
    EVENT_PORTFOLIO_HEALTH_OPENED: "Portfolio Health",
    EVENT_PORTFOLIO_QUALITY_OPENED: "Position Quality",
    EVENT_DAILY_PICKS_OPENED: "Daily Picks",
    EVENT_RADAR_OPENED: "Opportunity Radar",
    EVENT_MORNING_BRIEF_OPENED: "AI Morning Brief",
    EVENT_NOTIFICATION_OPENED: "Notifications",
    EVENT_JOURNAL_OPENED: "Portfolio Journal",
}


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("/demand")
def demand(
    authorization: Optional[str] = Header(default=None),
) -> dict:
    """Most Requested Features — ranked opens + unique users per feature."""
    _user_id(authorization)
    breakdown = get_sub_service().demand_breakdown()

    # Fold per (event, meta) rows into per-feature totals.
    totals: dict = {}
    for row in breakdown:
        metric = row.get("metric", "")
        label = _FEATURE_LABELS.get(metric)
        if label is None:
            continue  # ignore non-feature usage metrics (analysis/watchlist...)
        agg = totals.setdefault(label, {"opens": 0, "users": 0})
        agg["opens"] += int(row.get("total", 0))
        agg["users"] = max(agg["users"], int(row.get("users", 0)))

    most_requested = [
        {"feature": label, "opens": v["opens"], "users": v["users"]}
        for label, v in totals.items()
    ]
    most_requested.sort(key=lambda r: r["opens"], reverse=True)
    return {
        "most_requested_features": most_requested,
        "raw": breakdown,
    }
