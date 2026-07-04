---
title: Cross-Sectional Price Momentum (12-1)
slug: cross-sectional-momentum
stage: backtest
confidence: 78
evidence: 55
domains: [momentum, factor-investing, quantitative-trading]
frameworks: [momentum_score]
timeframe: position
regime: all
assets: [us-equities]
updated: 2026-07-04
---

## Definition
The empirical tendency for assets that outperformed their peers over the past
~3–12 months (skipping the most recent month) to continue outperforming over
the next 1–12 months, measured *cross-sectionally* (ranked against peers on the
same date), not against the asset's own history.

## Purpose
Feeds the TradeWizz `momentum_score`. Cross-sectional ranking is regime-robust
in construction (it is relative, so a broad market move cancels out) and is one
of the most replicated anomalies in finance, making it a strong evidence anchor
for the framework.

## Theory / Why it works
Two non-exclusive mechanisms in the literature:
1. **Under-reaction to information** (behavioral): investors update slowly to
   news, so prices drift toward fair value over months.
2. **Risk premium** (rational): momentum loads on a priced risk factor that
   pays a premium for bearing crash risk.
The classic "12-1" definition skips the most recent month to avoid the
well-documented **short-term (1-month) reversal**, which contaminates raw
12-month returns.

## When it works
- Trending markets with dispersion across names.
- Position / multi-week to multi-month horizons.
- Liquid equities where ranking is meaningful.

## When it fails
- **Momentum crashes**: sharp market reversals after a downturn (e.g. spring
  2009, early 2000s recoveries) devastate momentum portfolios — the losers
  rebound hardest, so shorting/underweighting them is punished. This is the
  single most important failure mode and MUST be risk-managed.
- Choppy / mean-reverting ranges: whipsaws.
- Very short horizons: dominated by 1-month reversal.
- Illiquid names: ranking driven by stale prices.

## Strengths
- Extremely well replicated (Jegadeesh-Titman 1993; Asness-Moskowitz-Pedersen
  2013 across asset classes and geographies).
- Cross-sectional construction is regime-neutral to *level* moves.
- Cheap to compute; explainable ("ranked in top decile of 12-1 return").

## Weaknesses
- Fat left tail (momentum crashes) — negative skew.
- Higher turnover than value → costs matter.
- Crowded factor; premium may be partly arbitraged.

## Risk
Negative skew: long stretches of steady gains punctuated by rare, severe
drawdowns. A user must never see momentum rank as a probability of profit; it
is a *relative-strength gauge* with known crash risk.

## Examples
A name in the top 10% of trailing 12-1 return among US equities, then held
1 month, historically shows positive average forward return relative to the
bottom decile.

## Counterexamples
Post-crash rebounds: in a sharp V-recovery, prior losers (bottom momentum
decile) can outperform prior winners for several months — the factor inverts.

## Implementation (rule spec)
- Signal per name on date t: cumulative return from t-252 to t-21 trading days
  (12 months minus the last ~1 month), using Adj Close.
- Universe: US equities with >= 200 valid daily bars and non-stale last price.
- Rank cross-sectionally into deciles on each rebalance date.
- Long-short evidence portfolio: top decile minus bottom decile, equal weight.
- Long-only production candidate: top decile / top quintile.
- Rebalance monthly (~21 trading days). Hold = rebalance interval.
- Risk overlay (future atom): scale exposure down when trailing market
  volatility spikes (momentum-crash guard).

## Backtesting ideas
With ~1 year of daily US data we can measure the **cross-sectional spread**:
form deciles at several rebalance dates, hold ~21 days, and compare forward
returns of top vs bottom decile. This is an in-sample, single-regime test:
- We CAN measure: sign and magnitude of the decile spread, monotonicity across
  deciles, hit rate, information coefficient (rank correlation of signal vs
  forward return).
- We CANNOT yet claim: multi-regime Sharpe, true max drawdown, crash behavior.
  Those require multi-year history → evidence capped per pipeline.md.

## Relationships to other concepts
- Complements **trend** (absolute) — momentum is relative, trend is absolute.
- Contaminated by **short-term reversal** (why we skip the last month).
- Needs **momentum-crash risk overlay** (planned atom) before production.
- Feeds framework `momentum_score`; combine with `liquidity_score` to avoid
  stale-price ranking.

## References
- Jegadeesh, N. & Titman, S. (1993). "Returns to Buying Winners and Selling
  Losers." Journal of Finance 48(1).
- Asness, C., Moskowitz, T. & Pedersen, L. (2013). "Value and Momentum
  Everywhere." Journal of Finance 68(3).
- Daniel, K. & Moskowitz, T. (2016). "Momentum Crashes." Journal of Financial
  Economics 122(2).

## Evidence log
- 2026-07-04: Stage-3 backtest RUN on live US cache. Harness:
  `research/backtests/cross-sectional-momentum/run.py`; results:
  `.../results.json`. Data window 2025-07-03 .. 2026-07-02 (251 common days,
  10,310 US symbols). SINGLE REGIME — evidence capped per pipeline.md.
  12-1 could NOT be tested (lookback exceeds available history); tested the
  standard 6-1 and 3-1 variants (both in Jegadeesh-Titman 1993).

  Measured (real numbers, not fabricated):
  - 6-1: 5 rebalances; mean IC +0.068 (60% positive); top-minus-bottom decile
    spread MEAN = -1.44%/hold; hit rate 60%; t-stat -0.32; monotonicity 0.14.
    Bottom decile OUTPERFORMED top decile on average -> factor INVERTED in this
    window (classic momentum-crash / mean-reversion failure mode).
  - 3-1: 8 rebalances; mean IC +0.064 (75% positive); top-minus-bottom spread
    MEAN = +0.90%/hold; hit rate 75%; t-stat +0.28; monotonicity 0.32.

  VERDICT: mean IC is positive and directionally consistent with the
  literature, BUT the spread t-stats are ~0 (|t|<0.32) on only 5-8 independent
  rebalances -> NOT statistically significant, and the 6-1 spread is negative.
  Conclusion: on OUR data (1y, single regime) the edge is WEAK and UNPROVEN.
  Per the four-stage gate, this concept does NOT advance to production. It
  stays at stage=backtest with low evidence until we have multi-regime history
  or a positive out-of-sample (Stage-4) result. Recorded, not discarded.

- 2026-07-04 (MULTI-YEAR, after backfill): re-run on the backfilled
  `period=max` liquid US universe. Harness
  `research/backtests/momentum-multiyear/run.py`; results `results.json`.
  Universe 343 liquid names; common calendar auto-extended to 5,140 days,
  **2006-01-26 .. 2026-07-02 (~20 years, MULTI-REGIME incl. 2008-09 GFC, 2020
  COVID crash, 2022 bear)**. Smaller cross-section than the 1y run -> higher
  per-rebalance noise, compensated by ~230 rebalances. Now the 12-1 signal is
  finally testable.

  Measured (real, not fabricated):
  - **12-1: 231 rebalances; mean IC +0.0247, IC t-stat 1.76; top-minus-bottom
    spread +0.71%/hold, t 1.10, hit 58.4%.** Positive, RIGHT sign, marginally
    significant.
  - 6-1: 237 reb; mean IC +0.0152, t 1.15; spread +0.47%/hold, hit 56.5%.
  - 3-1: 240 reb; mean IC +0.0000, t 0.003; spread +0.24%/hold, hit 55.0%.
  - **Horizon ordering over 20y: 12-1 > 6-1 > 3-1** (the LONGER lookback is
    stronger) -- the OPPOSITE of the 1y single-regime finding where 1-month
    looked best. Confirms the classic momentum result and flags the earlier
    short-term-momentum signal as a likely single-regime artifact.
  - **Regime dependence VISIBLE and matches literature:** 12-1 IC was strongly
    NEGATIVE in 2009 (IC -0.146, spread -7.0%) -- the textbook post-GFC
    momentum crash (Daniel-Moskowitz) -- and negative again in 2023 (spread
    -8.1%). Strong in 2013 (+0.124), 2017 (+0.103), 2022 (+0.147), 2024
    (+0.082). So the edge is real but crash-prone: a crash guard is mandatory.

  VERDICT: 12-1 momentum is now the STRONGEST-EVIDENCED concept in the
  institute -- correct sign, marginally significant (t 1.76) across 20 years
  and multiple regimes, with the documented crash signature. Confidence raised
  74->78, evidence 32->55 (multi-regime replication lifts the ceiling). Still
  NOT auto-promoted to production: (a) marginal significance (t<2), (b) the
  2009/2023 crashes mean a crash-guard atom must gate it, (c) universe is only
  343 liquid names -- a Stage-4 out-of-sample confirmation on a broader
  backfilled universe is the next requirement. Recorded.
