---
title: Short-Term Reversal (1-month)
slug: short-term-reversal
stage: backtest
confidence: 62
evidence: 30
domains: [reversal, mean-reversion, market-microstructure, quantitative-trading]
frameworks: [reversal_score, momentum_score]
timeframe: swing
regime: all
assets: [us-equities]
updated: 2026-07-04
---

## Definition
The empirical tendency for assets with the highest returns over the most recent
~1 month to UNDERPERFORM, and the biggest recent losers to OUTPERFORM, over the
following ~1 month — measured cross-sectionally against peers. It is the mirror
image of momentum at short horizons, and the exact effect the 12-1/6-1 momentum
signal deliberately skips.

## Purpose
Two jobs:
1. Explain and hedge the "skip month" in momentum: the last month is dropped
   from momentum precisely because reversal dominates there. Understanding it
   makes the momentum atom honest.
2. Candidate `reversal_score` for swing horizons — AND a diagnostic for the
   current regime. Our momentum backtest found the 6-1 variant INVERTED on 1y
   US data (losers beat winners), which is a reversal signature. This atom
   tests that directly.

## Theory / Why it works
- **Overreaction / liquidity provision** (Jegadeesh 1990; Lehmann 1990): buyers
  who demand immediacy push prices past fair value; liquidity providers earn
  the reversal as compensation. So short-term reversal is partly a payment for
  supplying liquidity, not free alpha.
- **Bid-ask bounce & microstructure noise**: measured 1-day/1-week reversals
  are heavily contaminated by the bid-ask bounce; using ~1-month horizons and
  liquid names reduces (not eliminates) this.
- **Distinct from De Bondt-Thaler long-term reversal (1985)**: that operates
  over 3–5 years (overreaction unwinding). Different mechanism, different
  horizon — a separate future atom.

## When it works
- Very short horizons (days to ~1 month), liquid names.
- Range-bound / mean-reverting regimes and after sharp dislocations.
- When paired with a liquidity filter (reversal is strongest, but least
  harvestable net of costs, in illiquid names).

## When it fails
- **In strong trends**, reversal loses to momentum — betting against a runaway
  winner is punished.
- **Net of costs**, much of the raw reversal is illusory: it lives largely in
  the bid-ask bounce and in illiquid names you cannot trade cheaply. This is
  the dominant real-world failure mode.
- Earnings/news drift can overwhelm mean reversion for individual names.

## Strengths
- Very well documented; complements momentum (opposite horizon).
- Directly testable on our 1y data; our momentum result already hints at it.
- Explainable ("recent 1-month loser, expected to bounce vs peers").

## Weaknesses
- Costs & microstructure eat most of the raw edge — MUST be evaluated net of a
  liquidity gate and realistic slippage.
- Negatively correlated with momentum: naive combination can cancel out.
- Regime-dependent (trend vs range).

## Risk
A reversal bet is "catch a falling knife" risk: buying recent losers means some
are falling for real, fundamental reasons and keep falling. Sizing and a
liquidity/quality gate are mandatory.

## Examples
A liquid large-cap down 15% over the last month with no fundamental break,
historically shows a positive average forward return vs peers over the next
month.

## Counterexamples
A stock down 40% on a fraud disclosure or guidance cut is not a reversal
candidate — it is a value trap; naive reversal would buy it and lose more.

## Implementation (rule spec)
- Signal per name on date t: NEGATIVE of the trailing ~21-day return
  ( -(P_t / P_{t-21} - 1) ), using Adj Close, so recent losers rank high.
- Universe: apply the liquidity-participation tradability gate FIRST (this atom
  is meaningless in illiquid names).
- Rank cross-sectionally into deciles; long top decile (biggest losers) minus
  bottom decile (biggest winners), equal weight.
- Rebalance every ~21 days; hold ~21 days.
- Report results BOTH before and after the liquidity gate to quantify how much
  edge is a stale-price/illiquidity artifact.

## Backtesting ideas
On our ~1y US data:
1. Measure the decile spread of the 1-month reversal signal (top-minus-bottom
   forward return), IC, monotonicity, hit rate, t-stat.
2. Compare WITH vs WITHOUT the liquidity gate — expect the raw (all-names)
   reversal to look stronger than the tradable-only reversal if it is an
   illiquidity artifact (ties back to the liquidity atom finding).
3. Contrast directly with the momentum atom's numbers on the same dates.

## Relationships to other concepts
- **Mirror of** cross-sectional-momentum (opposite horizon); explains its skip
  month. If reversal is strong and momentum weak on our data, the regime is
  mean-reverting.
- **Requires** liquidity-participation as a pre-filter (its edge is largely an
  illiquidity/bid-ask artifact otherwise).
- **Distinct from** long-term (3-5y) reversal (De Bondt-Thaler) — future atom.

## References
- Jegadeesh, N. (1990). "Evidence of Predictable Behavior of Security Returns."
  Journal of Finance 45(3).
- Lehmann, B. (1990). "Fads, Martingales, and Market Efficiency." Quarterly
  Journal of Economics 105(1).
- De Bondt, W. & Thaler, R. (1985). "Does the Stock Market Overreact?" Journal
  of Finance 40(3). [long-term reversal — related, separate horizon]

## Evidence log
- 2026-07-04: Stage-3 backtest RUN. Harness
  `research/backtests/short-term-reversal/run.py`; results `results.json`.
  9,822 US symbols, 2025-07-03..2026-07-02, 251 common days, 8 rebalances.
  SINGLE REGIME. Signal = NEGATIVE trailing 21d return (recent losers rank
  high). Measured (real numbers):

  ALL NAMES:     mean IC -0.092 (12.5% positive); top-minus-bottom -2.42%/hold;
                 hit rate 0.375; t-stat -1.04; decile monotonicity -0.94.
  TRADABLE ONLY: mean IC -0.097 (12.5% positive); top-minus-bottom -3.70%/hold;
                 hit rate 0.125; t-stat -1.49; decile monotonicity -0.90.

  VERDICT: SHORT-TERM REVERSAL IS REJECTED on our data. The IC is strongly and
  consistently NEGATIVE with near-perfect inverse monotonicity (-0.94). This
  means recent 1-month WINNERS outperformed and recent LOSERS underperformed
  over the next month -> the effect is SHORT-TERM MOMENTUM, the opposite of
  reversal, in this regime. This is the single cleanest cross-sectional signal
  we have measured so far (|monotonicity| ~0.9 vs ~0.1-0.3 for 6-1/3-1
  momentum). The liquidity gate STRENGTHENED it (tradable-only spread -3.70% vs
  all-names -2.42%), consistent with the liquidity atom: tradable names give a
  cleaner signal, not a weaker one.

  CROSS-ATOM RECONCILIATION: my earlier guess that the 6-1 momentum inversion
  meant a 'mean-reverting regime' was WRONG and is corrected by this test. The
  regime shows STRONG 1-month momentum + noisy/inverted 6-month momentum. The
  actionable signal is a SHORT-TERM (1-month) MOMENTUM atom, NOT reversal.
  Recorded, not discarded. This atom stays at stage=backtest with LOW evidence
  as a documented negative result; the positive knowledge (short-term momentum)
  is spun out into a new atom `short-term-momentum`.
