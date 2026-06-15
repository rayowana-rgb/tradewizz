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
