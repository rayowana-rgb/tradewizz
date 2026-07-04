---
title: Liquidity & Participation Score
slug: liquidity-participation
stage: backtest
confidence: 80
evidence: 40
domains: [liquidity, market-microstructure, volume-analysis, risk-management]
frameworks: [liquidity_score, participation_score, risk_score]
timeframe: all
regime: all
assets: [us-equities, etf]
updated: 2026-07-04
---

## Definition
A composite gauge of how easily a position can be entered/exited without moving
the price, and how much genuine trading interest ("participation") a name
attracts. Built from dollar volume, the Amihud illiquidity ratio (|return| per
dollar traded), turnover, and price-staleness / zero-volume day frequency.

## Purpose
Two jobs:
1. **Tradability gate** — screen out names that a retail user (or our own
   Moomoo bridge) cannot realistically transact in. Feeds `risk_score`.
2. **Signal hygiene / RISK** — illiquid names carry ~6.5x higher forward-return
   variance (measured, see Evidence log), so they are a direct RISK hazard
   (slippage, exit-inability). NOTE: our 1y test did NOT show illiquidity
   lowering the momentum IC (it was higher, likely a fat-tail rank artifact),
   so the justification for the pre-filter is RISK/tradability, not IC
   improvement. Liquidity is still a mandatory pre-filter before trusting any
   factor for a real user.

## Theory / Why it works
- **Amihud (2002)**: illiquidity = average of |daily return| / daily dollar
  volume. Higher = more price impact per dollar. Amihud showed illiquid stocks
  command a return premium (compensation for illiquidity) AND that illiquidity
  spikes in stress. For us the primary use is a *quality/tradability filter*,
  not a return factor.
- **Datar, Naik & Radcliffe (1998)**: turnover (volume / shares outstanding) is
  a liquidity proxy inversely related to future returns; we lack shares
  outstanding, so we approximate participation with dollar volume + its trend.
- **Stale-price problem** (Lo & MacKinlay; Asness et al. on illiquid factor
  contamination): infrequently traded names carry non-synchronous prices that
  bias correlations and rankings.

## When it works
- As a filter, essentially always: it is definitional, not predictive. A name
  with near-zero dollar volume genuinely cannot be traded at posted prices.
- Most valuable in broad universes containing many micro-caps / illiquid names
  (our US universe: 12k+ symbols, a large tail is illiquid).

## When it fails
- As a *return* factor (illiquidity premium), the premium is regime-dependent
  and inverts in liquidity crunches — do NOT use it as a return signal without
  its own backtest. Here it is a filter, so this failure mode is out of scope.
- Dollar-volume can be distorted by one-off spikes (news, index rebalances);
  use median, not mean.
- ETFs: turnover/Amihud mislead because creation/redemption provides liquidity
  off-tape. Treat ETFs with a separate rule.

## Strengths
- Definitional and explainable ("median $ volume $X; would take N days to exit
  at 10% of ADV").
- Cheap; needs only OHLCV, which we have.
- Improves EVERY downstream factor by removing stale-price noise.

## Weaknesses
- Without shares outstanding we approximate turnover imperfectly.
- Point-in-time only; historical liquidity regime not captured in 1y.

## Risk
A user acting on a signal in an illiquid name can face large slippage or
inability to exit. Mis-scoring liquidity is a direct risk-management failure.

## Examples
A mega-cap with $5B+ median daily dollar volume: liquidity_score ~ max, Amihud
~ 0. A $50k/day micro-cap: liquidity_score ~ min, high Amihud, frequent
zero/near-zero volume days -> excluded from cross-sectional ranking.

## Counterexamples
A normally-liquid name during a halt/low-volume holiday week can look illiquid
for a few days — why we use a trailing median window, not a single day.

## Implementation (rule spec)
Per symbol, over a trailing window (default 63 trading days ~ 3 months):
- dollar_volume_t = Close_t * Volume_t
- adv = median(dollar_volume) over window
- amihud = mean(|daily_return| / dollar_volume) over window, scaled
- zero_vol_frac = fraction of days with Volume == 0 or dollar_volume < $1k
- Combine into liquidity_score in [0,100] via cross-sectional percentile of a
  blend (higher adv -> higher; higher amihud / zero_vol_frac -> lower).
- Tradability gate: exclude from factor ranking if adv < $100k OR
  zero_vol_frac > 0.2.

## Backtesting ideas
This atom is validated differently from a return factor. Two testable claims on
our 1y US data:
1. **Coverage/filter claim**: what fraction of the 12k universe is
   non-tradable, and does excluding them change momentum results materially
   (re-run the momentum backtest with vs without the liquidity gate)?
2. **Stale-price claim**: do illiquid names have systematically noisier
   forward returns (higher variance, lower signal IC) than liquid names?
   Measurable: split universe by liquidity_score, compare momentum IC in each
   half.

## Relationships to other concepts
- **Pre-filter for** cross-sectional-momentum and all future factors.
- Complements **risk_score** (tradability).
- Related to a future **illiquidity-premium** return atom (separate, needs its
  own backtest).

## References
- Amihud, Y. (2002). "Illiquidity and stock returns: cross-section and
  time-series effects." Journal of Financial Markets 5(1).
- Datar, V., Naik, N. & Radcliffe, R. (1998). "Liquidity and stock returns: An
  alternative test." Journal of Financial Markets 1(2).
- Lo, A. & MacKinlay, A.C. (1990). "An econometric analysis of nonsynchronous
  trading." Journal of Econometrics 45.

## Evidence log
- 2026-07-04: Stage-3 backtest RUN. Harness
  `research/backtests/liquidity-participation/run.py`; results `results.json`.
  Data 2025-07-03..2026-07-02, 251 common days, 10,335 US symbols. SINGLE
  REGIME. Measured (real numbers):

  CLAIM A (tradability) -- VALIDATED, strong:
  - 19.3% of the universe (1,997 / 10,335) is NON-TRADABLE by the gate
    (median 63d $ volume < $100k OR >20% near-zero-volume days).
  - ADV median $1.64M; p10 $27.9k; p90 $129.7M -> extreme fat tail. ~1 in 5
    names cannot be transacted meaningfully by a retail user. The tradability
    gate is meaningful and should feed risk_score / pre-filter every factor.

  CLAIM B (signal hygiene) -- NUANCED; my specific hypothesis PARTLY REJECTED:
  - Forward-return VARIANCE far higher in the illiquid half: 0.267 vs 0.041
    (~6.5x). SUPPORTS the 'illiquid names are noisier/riskier' thesis and the
    core reason to gate them out for RISK.
  - BUT mean momentum IC was HIGHER in the illiquid half (0.084) than the
    liquid half (0.044), over 8 rebalances. This CONTRADICTS my hypothesis that
    illiquidity destroys signal content. Honest read: the higher rank-IC is
    almost certainly an artifact of the ~6.5x larger return variance/skew (rank
    correlation can rise with fatter tails), NOT a harvestable edge -- slippage
    and exit-inability would consume it. So we keep the gate for RISK, but we
    DROP the claim 'illiquidity lowers IC' as unsupported by our data.

  VERDICT: as a TRADABILITY / RISK FILTER the atom is validated (evidence 40)
  and is a sound pre-filter for cross-sectional factors. As an IC-improvement
  mechanism it is NOT supported here. It advances to stage=backtest as a
  filter; it will only enter production wired into risk_score after Stage-4
  live evaluation confirms the gate improves real decision quality.
