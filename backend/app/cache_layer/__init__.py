"""Shared in-process caching infrastructure.

A single, dependency-free TTL cache with per-key stampede protection and
hit/miss metrics, reused by Morning Brief, Global Rotation and Opportunity
Radar. Nothing here changes scoring, accounting, ranking, or API schemas — it
only memoizes the *result* of expensive read-only builds for a short TTL to
cut repeated Yahoo Finance / screener work.
"""

from __future__ import annotations

from .ttl_cache import TTLCache
from .cache_manager import CacheManager, get_cache_manager

__all__ = ["TTLCache", "CacheManager", "get_cache_manager"]
