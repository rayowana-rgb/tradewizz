"""Global market news service.

Aggregates yfinance per-symbol ``.news`` across a basket of *global* tickers
(US/EU/Asia indices, commodities, crypto, FX), normalizes provider payloads
into :class:`NewsItem`, de-duplicates by title, sorts newest-first, and caches
the result in-process for a short TTL. On a fetch failure it serves the last
good feed (stale-while-error) so the UI never goes blank.

The yfinance call is injected (``fetcher``) so tests stay offline/deterministic.
"""

from __future__ import annotations

import hashlib
import logging
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout
from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional

from .models import NewsFeed, NewsItem, NewsTopic

logger = logging.getLogger(__name__)

# A diversified global basket. yfinance returns ~10 fresh items per symbol for
# all of these; we merge + dedup so the feed reflects "the world today".
GLOBAL_SYMBOLS: List[str] = [
    "^GSPC",    # S&P 500
    "^IXIC",    # Nasdaq Composite
    "^DJI",     # Dow Jones
    "^GDAXI",   # Germany DAX (Europe)
    "^N225",    # Japan Nikkei 225 (Asia)
    "GC=F",     # Gold
    "CL=F",     # Crude oil (WTI)
    "BTC-USD",  # Bitcoin (crypto)
    "EURUSD=X",  # EUR/USD (FX)
]

# Per-symbol fetcher: takes a ticker, returns the raw yfinance ``.news`` list
# (a list of dicts). Injected for testability.
NewsFetcher = Callable[[str], List[dict]]

DEFAULT_TTL_SECONDS = 900  # 15 min — news doesn't need second-by-second polling
DEFAULT_LIMIT = 40
MIN_TOPICS = 3
MAX_TOPICS = 5

# Rule-based themes: (label, keywords). A headline joins a theme if it contains
# any keyword. Themes are scored by how many headlines match; the strongest are
# surfaced as "what the world is talking about". Order matters only as a
# tie-breaker (earlier = slightly preferred).
THEME_RULES: List[tuple] = [
    ("Oil & Energy", ("oil", "crude", "opec", "energy", "gas", "brent", "wti")),
    ("Fed & Rates", ("fed", "rate", "interest", "inflation", "cpi", "powell",
                      "central bank", "hike", "cut")),
    ("Stocks & Markets", ("stock", "shares", "equities", "s&p", "nasdaq",
                          "dow", "rally", "sell-off", "selloff", "futures",
                          "index")),
    ("Crypto", ("bitcoin", "crypto", "ethereum", "btc", "xrp", "dogecoin",
                "blockchain")),
    ("Currencies", ("dollar", "euro", "yen", "forex", "currency", "fx")),
    ("Gold & Metals", ("gold", "silver", "metal", "bullion")),
    ("Geopolitics", ("war", "peace", "iran", "gulf", "russia", "ukraine",
                     "china", "tariff", "sanction", "trump", "election")),
    ("Tech & AI", ("ai ", "artificial intelligence", "chip", "semiconductor",
                   "nvidia", "apple", "tesla", "spacex", "tech")),
    ("Earnings & Economy", ("earnings", "gdp", "jobs", "unemployment",
                            "economy", "recession", "growth", "retail")),
]


# Hard per-symbol timeout (seconds). yfinance's ``.news`` has no timeout knob
# and can hang indefinitely when Yahoo is slow/unreachable (notably off-market
# hours). An unbounded fetch stalls _build(), which holds the service lock, so
# every concurrent /v1/news request piles up on threadpool workers until the
# server stops responding. Bounding each call keeps the whole feed responsive.
_FETCH_TIMEOUT = 8.0

# A tiny dedicated pool so a hung provider call is isolated and abandoned (the
# orphaned worker dies on its own) instead of blocking the request thread.
_fetch_pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="news-yf")


def _default_fetcher(symbol: str) -> List[dict]:
    """Real fetch via yfinance, bounded by a hard timeout so it can never hang.

    Imported lazily to keep import light.
    """
    def _call() -> List[dict]:
        import yfinance as yf  # local import: heavy + only needed in production

        return yf.Ticker(symbol).news or []

    try:
        return _fetch_pool.submit(_call).result(timeout=_FETCH_TIMEOUT)
    except FuturesTimeout:
        logger.warning(
            "news fetch timed out for %s after %.0fs", symbol, _FETCH_TIMEOUT
        )
        return []
    except Exception as exc:  # noqa: BLE001 - provider is best-effort
        logger.warning("news fetch failed for %s: %s", symbol, exc)
        return []


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _norm_title(title: str) -> str:
    """Lowercase + strip non-alphanumerics for dedup keys."""
    return re.sub(r"[^a-z0-9]+", " ", (title or "").lower()).strip()


def _coerce(raw: dict, source_symbol: str) -> Optional[NewsItem]:
    """Map one yfinance news dict (v0.2.x ``content`` wrapper) to a NewsItem."""
    if not isinstance(raw, dict):
        return None
    c = raw.get("content")
    if not isinstance(c, dict):
        c = raw  # older yfinance flat shape

    title = (c.get("title") or "").strip()
    if not title:
        return None

    # Provider name (new shape: provider.displayName; old: publisher).
    provider = c.get("provider")
    if isinstance(provider, dict):
        publisher = provider.get("displayName") or ""
    else:
        publisher = c.get("publisher") or ""

    # URL (new: canonicalUrl/clickThroughUrl dicts; old: link).
    url = ""
    for key in ("canonicalUrl", "clickThroughUrl"):
        v = c.get(key)
        if isinstance(v, dict) and v.get("url"):
            url = v["url"]
            break
    if not url:
        url = c.get("link") or ""

    published_at = c.get("pubDate") or ""
    if not published_at:
        ts = c.get("providerPublishTime")
        if isinstance(ts, (int, float)):
            published_at = datetime.fromtimestamp(
                ts, tz=timezone.utc
            ).isoformat()

    summary = (c.get("summary") or c.get("description") or "").strip()

    thumbnail = None
    thumb = c.get("thumbnail")
    if isinstance(thumb, dict):
        res = thumb.get("resolutions")
        if isinstance(res, list) and res and isinstance(res[0], dict):
            thumbnail = res[0].get("url")

    raw_id = raw.get("id") or c.get("id") or url or title
    item_id = hashlib.sha1(str(raw_id).encode("utf-8")).hexdigest()[:16]

    return NewsItem(
        id=item_id,
        title=title,
        summary=summary,
        publisher=publisher,
        url=url,
        published_at=published_at,
        thumbnail=thumbnail,
        related_symbols=[source_symbol],
    )


def _topics(items: List[NewsItem]) -> List[NewsTopic]:
    """Rule-based 'what the world is talking about' (min 3 themes).

    Each headline is matched against keyword themes (a headline may match
    several). Themes are ranked by article count; the strongest are returned
    with a representative (newest) headline + related symbols. If fewer than
    MIN_TOPICS themes match, the most-recent uncategorized headlines fill the
    gap so the panel always shows at least 3 things.
    """
    matched: Dict[str, Dict] = {}
    used_titles: set = set()
    for item in items:
        text = f"{item.title} {item.summary}".lower()
        for label, keywords in THEME_RULES:
            if any(kw in text for kw in keywords):
                bucket = matched.setdefault(
                    label, {"count": 0, "headline": "", "symbols": set()}
                )
                bucket["count"] += 1
                # items are already newest-first -> first match is the newest.
                if not bucket["headline"]:
                    bucket["headline"] = item.title
                bucket["symbols"].update(item.related_symbols)
                used_titles.add(item.title)

    topics = [
        NewsTopic(
            label=label,
            headline=data["headline"],
            article_count=data["count"],
            symbols=sorted(data["symbols"]),
        )
        for label, data in matched.items()
    ]
    # Strongest themes first; tie-break by THEME_RULES order for stability.
    order = {label: i for i, (label, _) in enumerate(THEME_RULES)}
    topics.sort(key=lambda t: (-t.article_count, order.get(t.label, 99)))
    topics = topics[:MAX_TOPICS]

    # Guarantee at least MIN_TOPICS by filling with uncategorized headlines.
    if len(topics) < MIN_TOPICS:
        for item in items:
            if len(topics) >= MIN_TOPICS:
                break
            if item.title in used_titles:
                continue
            used_titles.add(item.title)
            topics.append(
                NewsTopic(
                    label="Today",
                    headline=item.title,
                    article_count=1,
                    symbols=item.related_symbols,
                )
            )
    return topics


class NewsService:
    """Builds + caches the global news feed."""

    def __init__(
        self,
        fetcher: Optional[NewsFetcher] = None,
        *,
        symbols: Optional[List[str]] = None,
        ttl_seconds: int = DEFAULT_TTL_SECONDS,
        limit: int = DEFAULT_LIMIT,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._fetch = fetcher or _default_fetcher
        self._symbols = symbols or GLOBAL_SYMBOLS
        self._ttl = ttl_seconds
        self._limit = limit
        self._clock = clock
        self._lock = threading.Lock()
        self._cache: Optional[NewsFeed] = None
        self._cached_at: float = 0.0
        # True while exactly one thread is rebuilding the feed. Concurrent
        # callers serve the current (stale) cache instead of blocking, so a
        # slow provider can never pile requests up on the threadpool.
        self._building = False

    def _build(self) -> NewsFeed:
        by_title: Dict[str, NewsItem] = {}
        for sym in self._symbols:
            for raw in self._fetch(sym):
                item = _coerce(raw, sym)
                if item is None:
                    continue
                key = _norm_title(item.title)
                if not key:
                    continue
                existing = by_title.get(key)
                if existing is None:
                    by_title[key] = item
                elif sym not in existing.related_symbols:
                    existing.related_symbols.append(sym)

        items = list(by_title.values())
        # Newest-first; items without a date sink to the bottom.
        items.sort(key=lambda i: i.published_at or "", reverse=True)
        items = items[: self._limit]

        return NewsFeed(
            scope="GLOBAL",
            generated_at=_now_iso(),
            topics=_topics(items),
            items=items,
            cached=False,
            fallback=False,
        )

    def feed(self, *, force: bool = False) -> NewsFeed:
        """Return the global feed, served from cache when fresh.

        On a build failure, returns the last good feed flagged ``fallback`` so
        the UI keeps showing content instead of an error.

        Single-flight: only one thread rebuilds at a time. If a rebuild is
        already in progress, concurrent callers return the current cached feed
        (flagged stale) rather than waiting — this keeps the endpoint fast and
        stops a slow upstream from exhausting the request threadpool.
        """
        with self._lock:
            fresh_cache = (
                self._cache is not None
                and (self._clock() - self._cached_at) < self._ttl
            )
            if fresh_cache and not force:
                cached = self._cache.model_copy()
                cached.cached = True
                return cached

            # A rebuild is already running: don't block, serve what we have.
            if self._building and self._cache is not None:
                stale = self._cache.model_copy()
                stale.cached = True
                stale.fallback = True
                return stale

            self._building = True

        # Build OUTSIDE the lock so other callers can read the cache meanwhile.
        try:
            feed = self._build()
            with self._lock:
                self._cache = feed
                self._cached_at = self._clock()
                self._building = False
            return feed.model_copy()
        except Exception as exc:  # noqa: BLE001 - serve stale on failure
            logger.warning("news build failed: %s", exc)
            with self._lock:
                self._building = False
                cache = self._cache
            if cache is not None:
                stale = cache.model_copy()
                stale.cached = True
                stale.fallback = True
                return stale
            raise

    def clear_cache(self) -> None:
        with self._lock:
            self._cache = None
            self._cached_at = 0.0
