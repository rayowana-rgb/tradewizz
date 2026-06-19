"""Order-book tradability proxy: high turnover but thin/gappy book is penalised.

Two names with IDENTICAL turnover/volume must NOT score the same liquidity if
one trades on a clean tight tape and the other on a thin, gappy queue with
no-trade days. This is the "value tinggi tapi ga likuid" case: value traded
overstates how easy the name is to enter/exit without moving price.
"""
from app import scoring
from app.models import Market


_BASE = dict(
    value_traded=5e9,
    avg_value_traded_20d=5e9,
    avg_value_traded=5e9,
    volume_ratio_20d=1.0,
    volume_ratio=1.0,
    avg_volume_20d=1e6,
    vol_mean_20=1e6,
)


def _ind(**over):
    d = dict(_BASE)
    d.update(over)
    return d


def test_factor_full_for_clean_tape():
    ind = _ind(illiquidity_impact=0.5, range_pct_20d=1.8, zero_volume_days_20d=0)
    assert scoring.tradability_factor(ind) == 1.0


def test_factor_floors_for_thin_gappy_tape():
    # p90-tail impact + wide range + several no-trade days => near the floor.
    ind = _ind(illiquidity_impact=400.0, range_pct_20d=14.0,
               zero_volume_days_20d=5)
    f = scoring.tradability_factor(ind)
    assert 0.55 <= f <= 0.62  # at/near the floor


def test_factor_is_one_when_proxies_missing():
    # Data-light rows must not be destabilised.
    assert scoring.tradability_factor(_ind()) == 1.0


def test_thin_book_scores_below_clean_book_at_same_turnover():
    clean = _ind(illiquidity_impact=0.3, range_pct_20d=1.8, zero_volume_days_20d=0)
    thin = _ind(illiquidity_impact=400.0, range_pct_20d=14.0,
                zero_volume_days_20d=5)
    s_clean = scoring.participation_score(clean, Market.IDX)
    s_thin = scoring.participation_score(thin, Market.IDX)
    assert s_thin < s_clean
    # Meaningful gap, not a rounding artifact.
    assert s_clean - s_thin >= 10.0


def test_factor_monotonic_in_impact():
    low = _ind(illiquidity_impact=10.0, range_pct_20d=2.0, zero_volume_days_20d=0)
    high = _ind(illiquidity_impact=250.0, range_pct_20d=2.0,
                zero_volume_days_20d=0)
    assert scoring.tradability_factor(high) < scoring.tradability_factor(low)


def test_factor_never_exceeds_one():
    # Negative/odd inputs must clamp.
    ind = _ind(illiquidity_impact=-5.0, range_pct_20d=-1.0, zero_volume_days_20d=0)
    assert scoring.tradability_factor(ind) <= 1.0
