"""Pydantic models for the in-app Notification Engine."""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel

# Notification type constants (wire names, used by the Flutter client too).
TYPE_ELITE_OPPORTUNITY = "new_elite_opportunity"
TYPE_MULTIBAGGER = "new_multibagger_candidate"
TYPE_PORTFOLIO_WARNING = "portfolio_health_warning"
TYPE_DAILY_PICK = "daily_pick_published"


class Notification(BaseModel):
    id: int = 0
    user_id: int
    notification_type: str
    title: str = ""
    body: str = ""
    symbol: Optional[str] = None
    market: Optional[str] = None
    created_at: str = ""
    read: bool = False


class NotificationList(BaseModel):
    notifications: List[Notification] = []
    unread_count: int = 0


class MarkReadRequest(BaseModel):
    # Mark specific ids read, or all when ids is empty/None.
    ids: Optional[List[int]] = None


class MarkReadResponse(BaseModel):
    user_id: int
    marked: int = 0
    unread_count: int = 0
