"""Pydantic models for the global market News feed.

The feed is sourced from yfinance's per-symbol ``.news`` across a basket of
*global* tickers (US/EU/Asia indices, commodities, crypto, FX). Items are
de-duplicated by title and sorted newest-first. This is *world market news*,
not Indonesia-specific (yfinance has almost no fresh IDX coverage).
"""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel


class NewsItem(BaseModel):
    """A single news headline surfaced from a provider via yfinance."""

    id: str
    title: str
    summary: str = ""
    publisher: str = ""           # e.g. "Reuters", "Bloomberg", "Yahoo Finance"
    url: str = ""                 # canonical article URL
    published_at: str = ""        # ISO-8601 (UTC) when available
    thumbnail: Optional[str] = None
    related_symbols: List[str] = []


class NewsFeed(BaseModel):
    """A de-duplicated, newest-first list of global market headlines."""

    scope: str = "GLOBAL"
    generated_at: str = ""        # ISO-8601 (UTC)
    items: List[NewsItem] = []
    cached: bool = False          # True when served from the in-memory cache
    fallback: bool = False        # True when served stale after a fetch failure
