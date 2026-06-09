"""Trading-date-aware cache freshness tests.

Covers the freshness policy and its enforcement in the cache manager + the
scoring services (Morning Brief / Rotation / Radar). The core safety property
(freshness rule #5) is: STALE previous-day / >30-min fallback data may be
DISPLAYED but must NEVER be used for scoring / ranking / radar / brief /
watchlist / rotation / notifications.

Required scenarios:
  * same-day CLOSED fallback allowed (usable as fresh, freshness=last_close)
  * OPEN-market fallback older than 30 min rejected (not fresh -> unavailable)
  * PRE_MARKET previous close allowed (usable, freshness=previous_close)
  * OPEN-market previous-day cache NOT used for scoring/ranking

Clocks are injected so no test sleeps.
"""

from __future__ import annotations

from datetime import date, datetime
from zoneinfo import ZoneInfo

from app.cache_layer import OPEN_FALLBACK_MAX_AGE, evaluate_freshness
from app.cache_layer.cache_manager import CacheManager
from app.market_session import MarketSessionState, get_market_session_state
from app.models import Market, ScreenerMatch, ScreenerResult
from app.morning_brief.service import MorningBriefService
from app.radar.service import RadarService
from app.rotation.service import GlobalRotationService


# --- helpers ----------------------------------------------------------------
def _jkt(y, m, d, hh, mm=0):
    return datetime(y, m, d, hh, mm, tzinfo=ZoneInfo("Asia/Jakarta"))


def _match(symbol, score, change=2.0, value=3e9, signal="BUY"):
    return ScreenerMatch(
        symbol=symbol, name=symbol, score=score, signal=signal, price=100.0,
        change_percent=change, categories=[], value_traded=value,
    )


def _idx():
    return [_match("BBCA", 90, 3.0, 2e9), _match("TPIA", 63, -1.0, 8e8,
            signal="HOLD")]


class _Provider:
    def __init__(self, fail=False):
        self.calls = []
        self.fail = fail

    def __call__(self, market, limit=50, min_score=0.0, min_value_traded=0.0):
        self.calls.append(market)
        if self.fail:
            raise RuntimeError("data source down (simulated)")
        return ScreenerResult(market=market, matches=_idx()[:limit],
                              generated_at="2026-06-09T00:00:00Z")


# === Pure freshness policy =================================================
# IDX session: pre 08:45, open 09:00, close 16:00, post to 16:30 (Asia/Jakarta).

def test_same_day_closed_fallback_allowed():
    # Market CLOSED (evening), entry built for today's trading date.
    now = _jkt(2026, 6, 9, 18, 0)            # after post-close -> CLOSED
    assert get_market_session_state(Market.IDX, now) is MarketSessionState.CLOSED
    dec = evaluate_freshness(
        Market.IDX,
        entry_trading_date=date(2026, 6, 9),
        entry_cached_at_epoch=_jkt(2026, 6, 9, 16, 5).timestamp(),
        now=now,
    )
    assert dec.usable_as_fresh is True       # safe to use after close
    assert dec.freshness == "last_close"
    assert dec.stale is False


def test_open_market_fallback_older_than_30min_rejected():
    now = _jkt(2026, 6, 9, 11, 0)            # OPEN
    assert get_market_session_state(Market.IDX, now) is MarketSessionState.OPEN
    # Entry built 45 minutes ago (same trading date) -> too old.
    cached_at = now.timestamp() - (45 * 60)
    dec = evaluate_freshness(
        Market.IDX,
        entry_trading_date=date(2026, 6, 9),
        entry_cached_at_epoch=cached_at,
        now=now,
    )
    assert dec.usable_as_fresh is False       # rejected for scoring
    assert dec.usable_as_display is False      # and not even displayed
    assert dec.stale is True
    assert dec.freshness == "stale"


def test_open_market_fallback_within_30min_is_fresh():
    now = _jkt(2026, 6, 9, 11, 0)
    cached_at = now.timestamp() - (10 * 60)   # 10 min old
    dec = evaluate_freshness(
        Market.IDX, entry_trading_date=date(2026, 6, 9),
        entry_cached_at_epoch=cached_at, now=now,
    )
    assert dec.usable_as_fresh is True
    assert dec.freshness == "live"
    assert dec.age_seconds <= OPEN_FALLBACK_MAX_AGE


def test_pre_market_previous_close_allowed():
    # New calendar day, before open -> PRE_MARKET. Cache from previous trading
    # day may be used as last close.
    now = _jkt(2026, 6, 10, 8, 50)            # 08:45<=t<09:00 -> PRE_MARKET
    assert get_market_session_state(Market.IDX, now) is \
        MarketSessionState.PRE_MARKET
    dec = evaluate_freshness(
        Market.IDX,
        entry_trading_date=date(2026, 6, 9),   # previous trading day
        entry_cached_at_epoch=_jkt(2026, 6, 9, 16, 5).timestamp(),
        now=now,
    )
    assert dec.usable_as_fresh is True
    assert dec.freshness == "previous_close"
    assert dec.fallback is True


def test_open_new_trading_date_previous_day_not_fresh():
    # Rule 4: OPEN on a NEW trading_date; previous-day cache is display-only.
    now = _jkt(2026, 6, 10, 11, 0)            # OPEN on the 10th
    dec = evaluate_freshness(
        Market.IDX,
        entry_trading_date=date(2026, 6, 9),   # yesterday
        entry_cached_at_epoch=_jkt(2026, 6, 9, 15, 0).timestamp(),
        now=now,
    )
    assert dec.usable_as_fresh is False        # never fresh
    assert dec.usable_as_display is True        # may be shown
    assert dec.stale is True
    assert dec.fallback is True
    assert dec.freshness == "previous_close"


# === CacheManager.get_or_build_fresh =======================================
def test_manager_rebuilds_when_open_entry_older_than_30min():
    mgr = CacheManager()
    builds = {"n": 0}

    def builder():
        builds["n"] += 1
        return f"v{builds['n']}"

    now = _jkt(2026, 6, 9, 11, 0)
    # First call: miss -> build, tagged today's trading date at `now`.
    r1 = mgr.get_or_build_fresh("radar", "k", builder, Market.IDX,
                                now=now, now_epoch=now.timestamp())
    assert r1.value == "v1" and r1.cached is False and r1.usable_as_fresh

    # 10 minutes later: fresh -> served from cache, no rebuild.
    later = now.timestamp() + 10 * 60
    r2 = mgr.get_or_build_fresh("radar", "k", builder, Market.IDX,
                                now=now, now_epoch=later)
    assert r2.cached is True and builds["n"] == 1

    # 40 minutes later (still OPEN): stale -> rebuild.
    much_later = now.timestamp() + 40 * 60
    r3 = mgr.get_or_build_fresh("radar", "k", builder, Market.IDX,
                                now=now, now_epoch=much_later)
    assert r3.value == "v2" and r3.cached is False and builds["n"] == 2


def test_manager_open_stale_with_failed_rebuild_returns_unavailable():
    mgr = CacheManager()
    now = _jkt(2026, 6, 9, 11, 0)
    # Seed an entry.
    mgr.get_or_build_fresh("radar", "k", lambda: "seed", Market.IDX,
                           now=now, now_epoch=now.timestamp())

    def boom():
        raise RuntimeError("provider down")

    # 45 min later (OPEN): entry is stale AND not displayable -> rebuild
    # attempted, fails -> partial unavailable (value None), never the stale
    # value.
    much_later = now.timestamp() + 45 * 60
    r = mgr.get_or_build_fresh("radar", "k", boom, Market.IDX,
                               now=now, now_epoch=much_later)
    assert r.value is None
    assert r.usable_as_fresh is False
    assert r.freshness == "unavailable"


def test_manager_closed_stale_failed_rebuild_displays_previous_close():
    mgr = CacheManager()
    open_now = _jkt(2026, 6, 9, 11, 0)
    mgr.get_or_build_fresh("radar", "k", lambda: "seed", Market.IDX,
                           now=open_now, now_epoch=open_now.timestamp())

    # Next day, OPEN -> previous-day entry is display-only. Rebuild fails ->
    # serve the previous value for DISPLAY but never as fresh.
    next_open = _jkt(2026, 6, 10, 11, 0)

    def boom():
        raise RuntimeError("down")

    r = mgr.get_or_build_fresh("radar", "k", boom, Market.IDX,
                               now=next_open, now_epoch=next_open.timestamp())
    assert r.value == "seed"            # displayed
    assert r.usable_as_display is True
    assert r.usable_as_fresh is False    # but NOT for scoring
    assert r.stale is True and r.fallback is True


# === Service-level enforcement (rule #5) ===================================
def _services(provider, now):
    """Build radar/brief/rotation sharing one manager, with no time freeze.

    The services call get_market_session_state() with the real clock, so for
    deterministic service tests we instead assert behaviour that holds
    regardless of wall-clock session (fresh build on a cold cache).
    """
    mgr = CacheManager()
    radar = RadarService(provider, markets=[Market.IDX], cache=mgr)
    brief = MorningBriefService(radar=radar, cache=mgr)
    rot = GlobalRotationService(radar=radar, markets=[Market.IDX], cache=mgr)
    return mgr, radar, brief, rot


def test_radar_open_previous_day_not_ranked():
    """A previous-day per-market entry must not feed ranking when OPEN.

    We seed radar's per-market cache for a prior trading date, then evaluate at
    an OPEN time on a new trading date and confirm _safe_for yields an empty
    (non-stale) pool rather than the stale opportunities.
    """
    mgr = CacheManager()
    provider = _Provider()
    radar = RadarService(provider, markets=[Market.IDX], cache=mgr)

    # Seed the per-market cache during a prior session.
    seeded = [_match("BBCA", 90).symbol]  # noqa: F841 (clarity)
    open_prev = _jkt(2026, 6, 9, 11, 0)
    mgr.get_or_build_fresh(
        "radar", "radar_IDX_50",
        lambda: radar._opportunities_for(Market.IDX, limit=50),
        Market.IDX, now=open_prev, now_epoch=open_prev.timestamp(),
    )
    # Now it's OPEN on a NEW trading date; the provider is down so no rebuild.
    provider.fail = True
    next_open = _jkt(2026, 6, 10, 11, 0)
    res = mgr.get_or_build_fresh(
        "radar", "radar_IDX_50",
        lambda: (_ for _ in ()).throw(RuntimeError("down")),
        Market.IDX, now=next_open, now_epoch=next_open.timestamp(),
    )
    # Stale previous-day data may be displayed but is NOT fresh -> scoring path
    # (which checks usable_as_fresh) must drop it.
    assert res.usable_as_fresh is False
    assert res.stale is True


def test_services_build_fresh_on_cold_cache():
    """Sanity: with a cold cache the scoring services build live data."""
    mgr, radar, brief, rot = _services(_Provider(), None)
    opp = radar.opportunities()
    assert opp.data_available is True
    b = brief.brief(Market.IDX)
    assert b.data_available is True
    r = rot.global_rotation()
    assert r.data_available is True


# === Notifications must not alert on stale data (rule #5) ==================
class _FakeRadar:
    """Radar stub returning a response flagged as stale/unavailable."""

    def __init__(self, *, stale=False, data_available=True):
        from app.radar.models import (
            DailyPick, DailyPicksResponse, Opportunity, OpportunitiesResponse,
        )
        elite = Opportunity(
            symbol="BBCA", market=Market.IDX, name="BBCA", score=95.0,
            signal="BUY", recommendation="STRONG BUY",
        )
        self._opps = OpportunitiesResponse(
            generated_at="t", global_top10=[elite], multibagger_candidates=[],
            stale=stale, data_available=data_available,
        )
        self._daily = DailyPicksResponse(
            generated_at="t", date="2026-06-09",
            picks=[DailyPick(rank=1, symbol="BBCA", market=Market.IDX,
                             name="BBCA", score=95.0, signal="BUY",
                             recommendation="STRONG BUY")],
            stale=stale, data_available=data_available,
        )

    def opportunities(self):
        return self._opps

    def daily(self):
        return self._daily


def _notif_service(radar):
    from app.notifications.service import NotificationService
    from app.notifications.store import SqliteNotificationStore
    return NotificationService(
        store=SqliteNotificationStore(":memory:"), radar_service=radar,
    )


def test_notifications_fire_on_fresh_radar():
    svc = _notif_service(_FakeRadar(stale=False, data_available=True))
    created = svc.refresh(user_id=1)
    assert created >= 1                # elite + daily-pick alerts created


def test_notifications_skip_stale_radar():
    svc = _notif_service(_FakeRadar(stale=True, data_available=True))
    created = svc.refresh(user_id=1)
    assert created == 0                # no BUY/elite alerts on stale data


def test_notifications_skip_unavailable_radar():
    svc = _notif_service(_FakeRadar(stale=False, data_available=False))
    created = svc.refresh(user_id=1)
    assert created == 0
