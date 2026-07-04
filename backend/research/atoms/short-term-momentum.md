---
title: Short-Term Momentum (1-month)
slug: short-term-momentum
stage: backtest
confidence: 32
evidence: 40
domains: [momentum, quantitative-trading, market-microstructure]
frameworks: [momentum_score]
timeframe: swing
regime: unknown
assets: [us-equities]
updated: 2026-07-04
---

## Definition
The tendency for assets with the highest returns over the most recent ~1 month
to CONTINUE outperforming peers over the next ~1 month (and recent losers to
keep underperforming), measured cross-sectionally. It is the sign-opposite of
the classical short-term REVERSAL effect, and was discovered empirically in our
own data while testing reversal.

## Purpose
This atom exists because the data forced it. We set out to test 1-month
reversal (a well-documented effect) and found the OPPOSITE with a very clean,
near-monotonic signal. Intellectual honesty requires recording the effect we
actually measured, not the one we expected. It is a candidate short-horizon
input to `momentum_score` — but with an explicit warning about why it is
theoretically fragile (see Weaknesses).

## Theory / Why it works
CAUTION — this is the theoretically WEAKEST atom, because it runs against the
best-documented short-horizon effect (reversal; Jegadeesh 1990, Lehmann 1990).
Possible honest explanations for what we measured:
1. **Regime-specific continuation**: in strongly trending regimes, short-term
   winners keep winning; the classical reversal premium can flip. Our window
   (2025-07..2026-07) may be such a regime.
2. **Overlap with the 6-1 anomaly**: the 6-1 momentum in our data was inverted;
   the 1-month component behaved like clean momentum. The two together suggest
   a specific regime, not a universal law.
3. **NOT a bid-ask/microstructure artifact of illiquidity**: the effect was
   STRONGER in the tradable-only universe, so it is not merely stale-price
   noise (which would concentrate in illiquid names).
We do NOT claim a durable behavioral/rational mechanism. This is an EMPIRICAL,
IN-SAMPLE, SINGLE-REGIME observation pending replication.

## When it works
- Observed in a trending ~1y US regime (2025-07..2026-07). Unknown elsewhere.
- Liquid names (effect was stronger among tradable names).

## When it fails
- The classical literature says the OPPOSITE (reversal) should dominate at this
  horizon on average across history. So the base-rate expectation is that this
  effect is REGIME-DEPENDENT and could invert in a different regime.
- Single-regime, in-sample: high risk of not generalizing. This is the primary
  failure mode and the reason evidence is capped and confidence kept low (55).
- Costs: 1-month rebalance turnover is high; net-of-cost edge unverified.

## Strengths
- Cleanest cross-sectional signal we have measured: near-monotonic deciles
  (|Spearman| ~0.9) and consistent negative-reversal / positive-continuation
  IC across 8 rebalances (only 1/8 positive for the reversal sign).
- Robust to the liquidity gate (strengthened, not weakened).

## Weaknesses
- Contradicts the dominant academic prior -> low confidence until replicated
  out-of-sample or in another regime.
- Single regime, 8 rebalances -> statistically suggestive, not conclusive
  (reversal-sign t-stat -1.0 to -1.5; i.e. the continuation sign is favored but
  not at high significance).
- High turnover.

## Risk
Acting on a fragile, regime-dependent effect that the literature says should
reverse is dangerous: it may work until the regime changes, then invert
sharply. Must NOT enter production without out-of-sample (Stage-4) confirmation
and a regime guard.

## Examples
A liquid name up strongly over the last month, in a trending market, tended to
keep outperforming peers over the next month in our sample.

## Counterexamples
The academic base case: across long history, 1-month winners tend to REVERSE.
Our result is the exception, tied to this regime.

## Implementation (rule spec)
- Signal per name on date t: trailing ~21-day return (P_t / P_{t-21} - 1),
  Adj Close.
- Apply liquidity-participation tradability gate FIRST.
- Rank cross-sectionally; long top decile (recent winners) minus bottom decile.
- Rebalance / hold ~21 days.
- MANDATORY regime guard before any production use (planned atom): disable when
  trailing market breadth/volatility signals a reversal-prone regime.

## Backtesting ideas
- Already measured (see Evidence log) as the sign-flip of the reversal test.
- NEXT: out-of-sample confirmation once multi-year data exists; test whether
  the effect survives realistic transaction costs; test interaction with 6-1
  momentum and with a regime filter.

## Relationships to other concepts
- Sign-opposite of short-term-reversal (same backtest, mirror signal).
- Short-horizon complement to cross-sectional-momentum (which was weak at 6-1).
- Requires liquidity-participation as a pre-filter.
- Needs a future regime-guard atom before production.

## References
- Discovered empirically in this project (see Evidence log). Runs COUNTER to:
  Jegadeesh, N. (1990), Journal of Finance 45(3); Lehmann, B. (1990), QJE
  105(1) — both document short-term REVERSAL. We cite them as the contrary
  prior, not as support.

## Evidence log
- 2026-07-04: Measured as the exact sign-flip of the reversal backtest
  (`research/backtests/short-term-reversal/run.py`, results.json). 9,822 US
  symbols, 2025-07-03..2026-07-02, 8 rebalances, single regime.
  Continuation (winners-minus-losers) spread was POSITIVE and near-monotonic:
  reversal IC -0.092 (all) / -0.097 (tradable) => continuation IC +0.092 /
  +0.097; decile monotonicity for the reversal sign -0.94 / -0.90 (i.e. clean
  momentum ordering); reversal t-stat -1.04 / -1.49. Tradable-only was STRONGER.
  IN-SAMPLE, SINGLE-REGIME, contradicts academic prior -> confidence 55,
  evidence 40, stays stage=backtest. NO production use without Stage-4 OOS proof
  and a regime guard.

- 2026-07-04 (MULTI-YEAR OUT-OF-SAMPLE, after backfill): the 20-year momentum
  re-test (`research/backtests/momentum-multiyear/run.py`) included the 3-1
  variant, whose short leg (1-month, skip-1) is the closest available proxy for
  this effect over 2006..2026. Result: **3-1 mean IC +0.0000, IC t-stat 0.003,
  spread +0.24%/hold, hit 55%** across 240 rebalances -- i.e. essentially ZERO
  edge over 20 years and multiple regimes. The clean 1-month CONTINUATION we
  saw in 2025-07..2026-07 does NOT generalize; it was a SINGLE-REGIME ARTIFACT
  of a strongly trending window, exactly as the academic prior warned.
  CONSEQUENCE: this atom FAILS the implicit Stage-4 out-of-sample test. It is
  DEMOTED (confidence 55 -> 32) and explicitly NOT a production candidate. The
  useful knowledge is retained: (1) short-horizon continuation exists in
  strongly trending regimes but averages to zero across history, (2) this
  vindicates keeping it out of production, (3) it is a cautionary example of
  why single-regime signals must never be trusted without OOS. The classical
  short-term REVERSAL prior stands on average; our reversal atom's rejection
  was itself regime-specific. Superseded as a candidate by 12-1 momentum.
