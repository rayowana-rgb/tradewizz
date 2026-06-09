"""System router — operational visibility into the shared cache.

``GET /v1/system/cache`` exposes hit/miss counters for the Morning Brief,
Global Rotation and Opportunity Radar caches. No authentication required (it
contains no user data — only aggregate counters).
"""

from __future__ import annotations

from typing import Dict

from fastapi import APIRouter

from ..cache_layer import CacheManager, get_cache_manager

router = APIRouter(prefix="/v1/system", tags=["system"])

_manager: CacheManager = get_cache_manager()


def set_cache_manager(manager: CacheManager) -> None:
    """Test hook: point the system router at a specific cache manager."""
    global _manager
    _manager = manager


@router.get("/cache")
def cache_metrics() -> Dict[str, int]:
    """Return flat hit/miss counters for every cache namespace.

    Example::

        {
          "morning_brief_hits": 120, "morning_brief_misses": 8,
          "rotation_hits": 55, "rotation_misses": 2,
          "radar_hits": 310, "radar_misses": 21
        }
    """
    return _manager.metrics()
