"""Phase 11B — liquidity-first scoring: participation is the dominant factor.

These tests pin the new contract on top of the existing engine:
  * value traded = 0 / weak avg value traded cannot score high;
  * a one-day volume/value spike with a weak 20-day average cannot become elite;
  * strong, consistent value traded improves ranking;
  * a liquid name outranks an illiquid technical name;
  * volume/value expansion ratios contribute positively;
  * liquidity_score / participation fields are exposed in the screener result;
  * final_score and the bot9 category bonus still work (regression guards).
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from app import indicators, scoring
from app.engine import AnalysisEngine
from app.models import Market, ScreenerCategory
from app import explore


# --------------------------------------------------------------------------- #
# Fixtures: identical strong uptrend price action, different liquidity.        #
# --------------------------------------------------------------------------- #
def _uptrend(n=300, start=100.0, step=1.0, volume=1.0):
    close = start + np.arange(n) * step
    vol = np.full(n, float(volume))
    return pd.DataFrame({
        "Open": close, "High": close + 1, "Low": close - 1,
        "Close": close, "Volume": vol,
    })


def _ind(df):
    return indicators.compute_all(df)


# --------------------------------------------------------------------------- #
# 1. value_traded = 0 cannot score high.                                       #
# --------------------------------------------------------------------------- #
def test_zero_value_traded_cannot_score_high():
    df = _uptrend(volume=0.0)  # no shares traded -> value_traded 0
    ind = _ind(df)
    score = scoring.technical_score(ind, None, Market.IDX)
    assert score <= 50.0
    assert scoring.participation_score(ind, Market.IDX) == 0.0


# --------------------------------------------------------------------------- #
# 2. Weak avg value traded caps the score even on perfect technicals.          #
# --------------------------------------------------------------------------- #
def test_weak_avg_value_traded_keeps_score_modest():
    # IDX price ~100..400, tiny volume -> value traded far below Rp1B floor.
    df = _uptrend(volume=10.0)
    ind = _ind(df)
    part = scoring.participation_score(ind, Market.IDX)
    assert part <= 45.0  # poor / weak band
    eng = AnalysisEngine(fetcher=lambda t, p, i: df)
    res = eng.analyze("WEAK", Market.IDX)
    # Illiquid cap + low participation -> never elite, never BUY.
    assert res.score <= 60.0
    assert res.signal != "BUY"


# --------------------------------------------------------------------------- #
# 3. One-day spike with weak avg value traded does not become elite.           #
# --------------------------------------------------------------------------- #
def test_one_day_spike_does_not_become_elite():
    n = 300
    close = 100 + np.arange(n) * 1.0
    vol = np.full(n, 100.0)        # chronically thin
    vol[-1] = 50_000_000.0         # single-day blow-off volume
    df = pd.DataFrame({"Open": close, "High": close + 1, "Low": close - 1,
                       "Close": close, "Volume": vol})
    ind = _ind(df)
    # Today's turnover is huge but the 20-day average is tiny; the stricter
    # anchor keeps participation (and the liquidity cap) honest.
    eng = AnalysisEngine(fetcher=lambda t, p, i: df)
    res = eng.analyze("PUMP", Market.IDX)
    assert res.score < 90.0
    assert res.signal != "BUY" or res.score < 75.0


# --------------------------------------------------------------------------- #
# 3b. A durably-liquid name with ONE quiet session is not penalized (IDX bug). #
# --------------------------------------------------------------------------- #
def test_quiet_day_on_a_liquid_name_is_not_capped():
    """Regression for the IDX liquidity-scoring bug.

    A name that durably trades heavy turnover (high 20-day average) but has a
    single thin session must keep its liquidity standing. Anchoring on
    ``min(today, avg)`` used to cap such names (e.g. GOTO on a Rp2.5B day vs a
    Rp19B average). The durable-average anchor fixes it.
    """
    n = 300
    close = 100 + np.arange(n) * 1.0
    # Heavy, consistent turnover -> durably liquid (well above every IDX cap).
    vol = np.full(n, 50_000_000.0)
    # Today is unusually quiet (1/40th of normal) but still a real session.
    vol[-1] = 1_250_000.0
    df = pd.DataFrame({"Open": close, "High": close + 1, "Low": close - 1,
                       "Close": close, "Volume": vol})
    ind = _ind(df)

    today = ind.get("value_traded")
    avg = ind.get("avg_value_traded_20d") or ind.get("avg_value_traded")
    assert today < avg  # genuinely a lull, not a pump

    # The liquidity cap must NOT fire: the durable average is far above the
    # top IDX tier, so an 80 BUY stays an 80 BUY.
    capped, signal, illiquid, reason = scoring.apply_liquidity_cap(
        80.0, "BUY", ind, Market.IDX
    )
    assert reason is None
    assert capped == 80.0
    assert signal == "BUY"
    assert not illiquid
    # Participation stays strong despite the quiet day.
    assert scoring.participation_score(ind, Market.IDX) >= 75.0


# --------------------------------------------------------------------------- #
# 4. Strong, consistent value traded improves ranking vs the thin name.        #
# --------------------------------------------------------------------------- #
def test_strong_value_traded_improves_ranking():
    strong = _uptrend(volume=2_000_000.0)   # huge IDX turnover (price*vol)
    thin = _uptrend(volume=200.0)
    s_strong = scoring.technical_score(_ind(strong), None, Market.IDX)
    s_thin = scoring.technical_score(_ind(thin), None, Market.IDX)
    assert s_strong > s_thin


# --------------------------------------------------------------------------- #
# 5. A liquid name outranks an illiquid technical name.                        #
# --------------------------------------------------------------------------- #
def test_liquid_outranks_illiquid_technical():
    # Illiquid: pristine technicals, thin volume.
    illiquid = _uptrend(volume=100.0)
    # Liquid: slightly noisier price but heavy, consistent turnover.
    rng = np.random.default_rng(7)
    n = 300
    close = 100 + np.arange(n) * 0.9 + rng.normal(0, 0.5, n)
    vol = np.full(n, 3_000_000.0)
    liquid = pd.DataFrame({"Open": close, "High": close + 1, "Low": close - 1,
                           "Close": close, "Volume": vol})
    s_illiquid = scoring.technical_score(_ind(illiquid), None, Market.IDX)
    s_liquid = scoring.technical_score(_ind(liquid), None, Market.IDX)
    assert s_liquid > s_illiquid


# --------------------------------------------------------------------------- #
# 6. Volume / value expansion contributes positively.                          #
# --------------------------------------------------------------------------- #
def test_expansion_contributes_positively():
    base = {"volume_ratio_20d": 1.0, "value_traded_ratio_20d": 1.0}
    rising = {"volume_ratio_20d": 2.5, "value_traded_ratio_20d": 2.2}
    assert (scoring.volume_expansion_score(rising)
            > scoring.volume_expansion_score(base))


# --------------------------------------------------------------------------- #
# 7. Mock / fallback rows still cannot get a BUY / elite (regression).         #
# --------------------------------------------------------------------------- #
def test_mock_fallback_cannot_be_elite():
    overlay = explore.compute_overlay(82.0, [ScreenerCategory.bullish], {},
                                      allow_bonus=False)
    assert overlay["category_bonus"] == 0
    assert overlay["conviction_score"] == 0
    assert overlay["final_score"] == 82.0  # == base, no overlay lift


# --------------------------------------------------------------------------- #
# 8 + 9. liquidity_score and final_score exist in the screener result.         #
# --------------------------------------------------------------------------- #
def test_liquidity_and_final_score_exposed():
    df = _uptrend(volume=3_000_000.0)
    eng = AnalysisEngine(fetcher=lambda t, p, i: df)
    match = eng._screen_one(
        "BBCA", Market.IDX, {"BBCA": "Bank Central Asia"}
    )
    assert match.final_score is not None
    assert match.liquidity_score is not None
    assert match.participation_score == match.liquidity_score
    assert match.value_traded_today is not None
    assert match.avg_value_traded_20d is not None
    assert match.volume_today is not None
    assert match.avg_volume_20d is not None


# --------------------------------------------------------------------------- #
# 10. bot9 category bonus still works (regression).                            #
# --------------------------------------------------------------------------- #
def test_category_bonus_still_works():
    assert explore.category_bonus([ScreenerCategory.accumulation_silent]) == 15
    assert explore.category_bonus([ScreenerCategory.short_candidate]) == 0
