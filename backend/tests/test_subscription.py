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


def _svc(preview_mode: bool = False):
    # Default to enforcement-armed (preview_mode=False) so these tests verify
    # the dormant paywall infrastructure still works when re-armed. A separate
    # block below verifies that preview_mode=True disables all enforcement.
    return SubscriptionService(
        store=SqliteSubscriptionStore(":memory:"),
        preview_mode=preview_mode,
    )


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
        preview_mode=False,
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


# --- PRO/ELITE Preview pivot: enforcement is dormant, demand is measured ----


def _preview_svc():
    return _svc(preview_mode=True)


def test_preview_mode_disables_feature_gating():
    svc = _preview_svc()
    assert svc.preview_mode is True
    # A brand-new FREE user can open every premium feature: no 402.
    svc.require_feature(1, FEATURE_OPPORTUNITY_RADAR)
    svc.require_feature(1, FEATURE_PORTFOLIO_HEALTH)
    svc.require_feature(1, FEATURE_MULTIBAGGER)


def test_preview_mode_removes_screener_cap():
    svc = _preview_svc()
    # FREE would normally clamp to 20; preview returns the requested limit.
    assert svc.cap_screener_limit(1, 200) == 200


def test_preview_mode_removes_daily_analysis_limit():
    svc = _preview_svc()
    # Far beyond the old FREE cap of 5/day; never raises.
    for _ in range(50):
        svc.check_and_count_analysis(1)
    # Usage is still recorded so we keep measuring demand.
    assert svc.usage_summary(1)[METRIC_ANALYSIS] == 50


def test_preview_entitlements_unlock_all_features():
    svc = _preview_svc()
    ent = svc.entitlements(1)
    assert ent.preview is True
    # FREE tier on record, but the app receives the full ELITE feature set.
    assert ent.tier == FREE
    assert FEATURE_OPPORTUNITY_RADAR in ent.features
    assert FEATURE_PORTFOLIO_HEALTH in ent.features
    assert FEATURE_MULTIBAGGER in ent.features
    assert ent.usage.analysis_limit == UNLIMITED
    # The premium features are flagged for PRO/ELITE PREVIEW badging.
    assert FEATURE_OPPORTUNITY_RADAR in ent.preview_features
    assert FREE not in ent.preview_features  # FREE features are never badged


def test_plans_reports_preview_flag():
    assert _preview_svc().plans()["preview"] is True
    assert _svc(preview_mode=False).plans()["preview"] is False


def test_join_waitlist_records_event_no_payment():
    svc = _preview_svc()
    res = svc.join_waitlist(1, "pro")
    assert res["status"] == "waitlisted"
    assert res["tier"] == PRO
    assert res["preview"] is True
    assert "waiting list" in res["message"].lower()
    # The join is recorded for demand analytics; tier is unchanged (no upgrade).
    assert svc.get_subscription(1).tier == FREE
    assert svc.usage_summary(1)["waitlist_joined"] == 1


def test_preview_event_demand_breakdown():
    svc = _preview_svc()
    svc.record_preview_event(1, "radar_opened", meta="US")
    svc.record_preview_event(2, "radar_opened", meta="US")
    svc.record_preview_event(1, "radar_opened", meta="IDX")
    svc.record_preview_event(1, "multibagger_opened", meta="IDX")
    rows = svc.demand_breakdown("radar_opened")
    # (radar_opened, US) seen by 2 users, 2 total; (radar_opened, IDX) by 1.
    us = next(r for r in rows if r["meta"] == "US")
    assert us["total"] == 2 and us["users"] == 2
    # Scoping to one metric excludes multibagger_opened.
    assert all(r["metric"] == "radar_opened" for r in rows)
    # Unscoped breakdown includes every event.
    metrics = {r["metric"] for r in svc.demand_breakdown()}
    assert {"radar_opened", "multibagger_opened"} <= metrics
