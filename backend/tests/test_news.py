"""Unit tests for the global news service (offline, mocked fetcher)."""

from __future__ import annotations

from app.news.service import NewsService


def _story(title, pub="Reuters", date="2026-06-15T03:00:00Z", url=None):
    return {
        "id": title,
        "content": {
            "title": title,
            "summary": f"summary of {title}",
            "provider": {"displayName": pub},
            "pubDate": date,
            "canonicalUrl": {"url": url or f"https://x/{title}"},
            "thumbnail": {"resolutions": [{"url": "https://img/x.jpg"}]},
        },
    }


def test_coerce_and_sort_newest_first():
    feed_data = {
        "^GSPC": [
            _story("Older headline", date="2026-06-14T00:00:00Z"),
            _story("Newest headline", date="2026-06-15T09:00:00Z"),
        ],
    }
    svc = NewsService(fetcher=lambda s: feed_data.get(s, []),
                      symbols=["^GSPC"])
    feed = svc.feed()
    assert [i.title for i in feed.items] == ["Newest headline", "Older headline"]
    top = feed.items[0]
    assert top.publisher == "Reuters"
    assert top.url == "https://x/Newest headline"
    assert top.summary.startswith("summary of")
    assert top.thumbnail == "https://img/x.jpg"
    assert top.related_symbols == ["^GSPC"]
    assert feed.cached is False


def test_dedup_by_title_across_symbols():
    shared = _story("Global stocks rally")
    data = {"^GSPC": [shared], "^IXIC": [shared]}
    svc = NewsService(fetcher=lambda s: data.get(s, []),
                      symbols=["^GSPC", "^IXIC"])
    feed = svc.feed()
    assert len(feed.items) == 1
    # Both source symbols recorded on the single merged item.
    assert set(feed.items[0].related_symbols) == {"^GSPC", "^IXIC"}


def test_cache_then_force_refresh():
    calls = {"n": 0}

    def fetcher(_sym):
        calls["n"] += 1
        return [_story(f"H{calls['n']}")]

    svc = NewsService(fetcher=fetcher, symbols=["^GSPC"], ttl_seconds=999)
    f1 = svc.feed()
    assert f1.cached is False
    f2 = svc.feed()  # within TTL -> cached
    assert f2.cached is True
    assert f2.items[0].title == f1.items[0].title
    f3 = svc.feed(force=True)  # bypass cache
    assert f3.cached is False
    assert f3.items[0].title != f1.items[0].title


def test_stale_fallback_on_failure():
    state = {"fail": False}

    def fetcher(_sym):
        if state["fail"]:
            raise RuntimeError("provider down")
        return [_story("Good headline")]

    svc = NewsService(fetcher=fetcher, symbols=["^GSPC"], ttl_seconds=0)
    good = svc.feed()
    assert good.items[0].title == "Good headline"
    state["fail"] = True
    stale = svc.feed()  # ttl=0 forces rebuild -> fails -> serve last good
    assert stale.fallback is True
    assert stale.cached is True
    assert stale.items[0].title == "Good headline"


def test_skips_items_without_title():
    data = {"^GSPC": [{"content": {"title": ""}}, _story("Real one")]}
    svc = NewsService(fetcher=lambda s: data.get(s, []), symbols=["^GSPC"])
    feed = svc.feed()
    assert [i.title for i in feed.items] == ["Real one"]


def test_topics_cluster_by_theme():
    data = {
        "^GSPC": [
            _story("Oil prices plunge as OPEC boosts supply",
                   date="2026-06-15T09:00:00Z"),
            _story("Crude slides on demand worries",
                   date="2026-06-15T08:00:00Z"),
            _story("Fed signals another rate cut amid cooling inflation",
                   date="2026-06-15T07:00:00Z"),
            _story("Bitcoin rallies past new highs",
                   date="2026-06-15T06:00:00Z"),
        ],
    }
    svc = NewsService(fetcher=lambda s: data.get(s, []), symbols=["^GSPC"])
    feed = svc.feed()
    assert len(feed.topics) >= 3
    labels = [t.label for t in feed.topics]
    # Oil theme has 2 articles -> ranked first.
    assert labels[0] == "Oil & Energy"
    assert feed.topics[0].article_count == 2
    # Representative headline = newest matching headline.
    assert "Oil prices plunge" in feed.topics[0].headline
    assert {"Fed & Rates", "Crypto"}.issubset(set(labels))


def test_topics_always_min_three():
    # Only one categorizable headline -> filler ensures >= 3 topics.
    data = {
        "^GSPC": [
            _story("Gold hits record high", date="2026-06-15T09:00:00Z"),
            _story("Local festival draws crowds",
                   date="2026-06-15T08:00:00Z"),
            _story("New museum opens downtown",
                   date="2026-06-15T07:00:00Z"),
        ],
    }
    svc = NewsService(fetcher=lambda s: data.get(s, []), symbols=["^GSPC"])
    feed = svc.feed()
    assert len(feed.topics) >= 3


def test_default_fetcher_bounds_a_hanging_provider(monkeypatch):
    """A yfinance call that never returns must not hang the fetch.

    Regression: ``yf.Ticker(sym).news`` has no timeout and once stalled the
    whole /v1/news request (and its threadpool worker), wedging the server.
    The bounded fetcher must give up and return [] instead of blocking.
    """
    import time as _time

    from app.news import service as news_service

    # Shrink the timeout so the test is fast.
    monkeypatch.setattr(news_service, "_FETCH_TIMEOUT", 0.3)

    class _HangingTicker:
        def __init__(self, *_a, **_k):
            pass

        @property
        def news(self):
            _time.sleep(5)  # would hang far past the timeout
            return [{"content": {"title": "never seen"}}]

    fake_yf = type("_YF", (), {"Ticker": _HangingTicker})
    monkeypatch.setitem(__import__("sys").modules, "yfinance", fake_yf)

    start = _time.monotonic()
    out = news_service._default_fetcher("^GSPC")
    elapsed = _time.monotonic() - start

    assert out == []
    assert elapsed < 2.0  # bounded by the (shrunk) timeout, not the 5s sleep


def test_concurrent_rebuild_serves_stale_without_blocking():
    """While one thread rebuilds, a concurrent caller gets cached data fast."""
    import threading
    import time as _time

    release = threading.Event()
    calls = {"n": 0}

    def slow_fetcher(sym):
        calls["n"] += 1
        if calls["n"] == 1:
            return [_story("First build story")]
        release.wait(2.0)  # second build blocks until released
        return [_story("Second build story")]

    svc = NewsService(fetcher=slow_fetcher, symbols=["^GSPC"], ttl_seconds=0)
    # Prime the cache (build #1).
    first = svc.feed()
    assert first.items

    # Build #2 (slow) in a background thread.
    t = threading.Thread(target=svc.feed)
    t.start()
    _time.sleep(0.1)  # let the background build start + hold _building

    # Concurrent caller must NOT block on the slow build: returns stale fast.
    began = _time.monotonic()
    concurrent = svc.feed()
    assert (_time.monotonic() - began) < 0.5
    assert concurrent.cached is True
    assert concurrent.fallback is True

    release.set()
    t.join(timeout=3)
