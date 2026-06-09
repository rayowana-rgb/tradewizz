"""Unit tests for subscription tiers, entitlements, limits, and analytics."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.subscription.entitlements import (
    ELITE,
    FEATURE_MULTIBAGGER,
    FEATURE_OPPORTUNITY_RADAR,
    FEATURE_PORTFOLIO_HEALTH,
    FREE,
    PRO,
    UNLIMITED,
    feature_matrix,
    limits_for,
    tier_includes,
)
from app.subscription.service import (
    METRIC_ANALYSIS,
    SubscriptionError,
    SubscriptionService,
)
from app.subscription.store import SqliteSubscriptionStore


def _svc():
    return SubscriptionService(store=SqliteSubscriptionStore(":memory:"))


def test_free_limits():
    lim = limits_for(FREE)
    assert lim.watchlist_max == 20
    assert lim.analysis_per_day == 5
    assert lim.screener_max_results == 20


def test_pro_and_elite_are_unlimited_core():
    for tier in (PRO, ELITE):
        lim = limits_for(tier)
        assert lim.watchlist_max == UNLIMITED
        assert lim.analysis_per_day == UNLIMITED
        assert lim.screener_max_results == UNLIMITED


def test_feature_gating_by_tier():
    # FREE has none of the premium features.
    assert not tier_includes(FREE, FEATURE_OPPORTUNITY_RADAR)
    assert not tier_includes(FREE, FEATURE_PORTFOLIO_HEALTH)
    # PRO unlocks the radar but not portfolio health.
    assert tier_includes(PRO, FEATURE_OPPORTUNITY_RADAR)
    assert not tier_includes(PRO, FEATURE_PORTFOLIO_HEALTH)
    # ELITE unlocks everything PRO has plus portfolio health + multibagger.
    assert tier_includes(ELITE, FEATURE_OPPORTUNITY_RADAR)
    assert tier_includes(ELITE, FEATURE_PORTFOLIO_HEALTH)
    assert tier_includes(ELITE, FEATURE_MULTIBAGGER)


def test_new_user_defaults_to_free():
    svc = _svc()
    sub = svc.get_subscription(1)
    assert sub.tier == FREE
    assert sub.active is True
    assert sub.expires_at is None


def test_upgrade_to_pro_then_elite():
    svc = _svc()
    pro = svc.upgrade(7, "pro")
    assert pro.tier == PRO
    assert pro.expires_at is not None
    assert svc.has_feature(7, FEATURE_OPPORTUNITY_RADAR)
    assert not svc.has_feature(7, FEATURE_PORTFOLIO_HEALTH)

    elite = svc.upgrade(7, "elite")
    assert elite.tier == ELITE
    assert svc.has_feature(7, FEATURE_PORTFOLIO_HEALTH)


def test_require_feature_raises_402_for_free():
    svc = _svc()
    with pytest.raises(SubscriptionError) as ei:
        svc.require_feature(3, FEATURE_OPPORTUNITY_RADAR)
    assert ei.value.status_code == 402
    assert ei.value.extra["required_tier"] == PRO


def test_screener_cap_for_free_and_pro():
    svc = _svc()
    # FREE clamps to 20.
    assert svc.cap_screener_limit(9, 200) == 20
    # PRO is uncapped.
    svc.upgrade(9, "pro")
    assert svc.cap_screener_limit(9, 200) == 200


def test_daily_analysis_limit_enforced_for_free():
    svc = _svc()
    # 5 allowed, 6th raises 402.
    for i in range(5):
        assert svc.check_and_count_analysis(42) == i + 1
    with pytest.raises(SubscriptionError) as ei:
        svc.check_and_count_analysis(42)
    assert ei.value.status_code == 402
    assert ei.value.extra["required_tier"] == PRO


def test_pro_has_unlimited_analysis():
    svc = _svc()
    svc.upgrade(42, "pro")
    for _ in range(50):
        svc.check_and_count_analysis(42)  # never raises
    ent = svc.entitlements(42)
    assert ent.usage.analysis_remaining == UNLIMITED


def test_entitlements_report_usage():
    svc = _svc()
    svc.check_and_count_analysis(5)
    svc.check_and_count_analysis(5)
    ent = svc.entitlements(5)
    assert ent.tier == FREE
    assert ent.usage.analysis_count == 2
    assert ent.usage.analysis_limit == 5
    assert ent.usage.analysis_remaining == 3


def test_auto_expire_downgrades_to_free():
    # A PRO sub whose expiry is in the past auto-downgrades to FREE.
    past = datetime(2000, 1, 1, tzinfo=timezone.utc)
    svc = SubscriptionService(
        store=SqliteSubscriptionStore(":memory:"),
        clock=lambda: past,
    )
    svc.upgrade(11, "pro")  # expires 30 days after 2000-01-01
    # Advance the clock far past expiry.
    svc._clock = lambda: datetime(2030, 1, 1, tzinfo=timezone.utc)
    sub = svc.get_subscription(11)
    assert sub.tier == FREE


def test_usage_analytics_summary():
    svc = _svc()
    svc.record_usage(8, "radar_view")
    svc.record_usage(8, "radar_view")
    svc.record_usage(8, "watchlist_usage")
    totals = svc.usage_summary(8)
    assert totals["radar_view"] == 2
    assert totals["watchlist_usage"] == 1


def test_feature_matrix_shape():
    fm = feature_matrix()
    tiers = {t["tier"] for t in fm["tiers"]}
    assert tiers == {FREE, PRO, ELITE}
    # Every feature lists a min_tier and a per-tier flag map.
    for f in fm["features"]:
        assert "key" in f and "min_tier" in f and "label" in f
        assert set(f["tiers"]) == {FREE, PRO, ELITE}
