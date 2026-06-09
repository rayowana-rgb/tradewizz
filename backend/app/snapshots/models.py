"""Pydantic models for the snapshot endpoints (Phase A/B/C).

Each section is an open mapping (``Dict[str, Any]``) holding the serialized
output of an existing service. Keeping sections as passthrough dicts means the
snapshot layer never has to re-declare (and risk drifting from) every nested
model in Morning Brief / Rotation / Radar / Portfolio, while the OpenAPI schema
still documents the top-level shape.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class DashboardSnapshot(BaseModel):
    generated_at: str
    market: str
    # Each section mirrors an existing endpoint's response, or is null when the
    # section could not be produced (the app then keeps its own cached copy).
    indices: Optional[Dict[str, Any]] = None
    morning_brief: Optional[Dict[str, Any]] = None
    rotation: Optional[Dict[str, Any]] = None
    radar: Optional[Dict[str, Any]] = None
    daily_picks: Optional[Dict[str, Any]] = None
    multibagger: Optional[Dict[str, Any]] = None
    watchlist_ai: Optional[Dict[str, Any]] = None
    notifications: Optional[Dict[str, Any]] = None
    # Per-section freshness (seconds since each section was last computed).
    section_ages: Dict[str, float] = Field(default_factory=dict)


class PortfolioSnapshot(BaseModel):
    generated_at: str
    account: Optional[Dict[str, Any]] = None
    positions: List[Dict[str, Any]] = Field(default_factory=list)
    portfolio_health: Optional[Dict[str, Any]] = None
    portfolio_quality: List[Dict[str, Any]] = Field(default_factory=list)
    portfolio_manager: Optional[Dict[str, Any]] = None


class WatchlistSnapshot(BaseModel):
    generated_at: str
    market: str
    watchlist_ai: List[Dict[str, Any]] = Field(default_factory=list)
    rotation: Optional[Dict[str, Any]] = None
    daily_picks: List[Dict[str, Any]] = Field(default_factory=list)
