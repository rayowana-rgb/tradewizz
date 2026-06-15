"""FastAPI router for /v1/news — the global market news feed.

Open to all (research only, no auth gate). Sourced from yfinance across a
global basket of tickers; see :mod:`app.news.service`.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, HTTPException, Query

from .models import NewsFeed
from .service import NewsService

router = APIRouter(prefix="/v1/news", tags=["news"])

_service: Optional[NewsService] = None


def set_service(service: NewsService) -> None:
    global _service
    _service = service


def get_service() -> NewsService:
    if _service is None:
        raise HTTPException(status_code=503, detail="News not ready.")
    return _service


@router.get("", response_model=NewsFeed)
@router.get("/", response_model=NewsFeed)
def global_news(
    force_refresh: bool = Query(default=False),
) -> NewsFeed:
    """Return the de-duplicated, newest-first global market news feed."""
    return get_service().feed(force=force_refresh)
