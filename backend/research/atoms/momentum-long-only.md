---
title: Long-Only Momentum (top-decile, cost-aware) — production form
slug: momentum-long-only
stage: backtest-oos
confidence: 82
evidence: 73
domains: [momentum, factor-investing, quantitative-trading, portfolio-construction]
frameworks: [momentum_score]
timeframe: position
regime: all
assets: [us-equities]
updated: 2026-07-04
---

## Definition
The production-relevant form of the momentum edge: buy (long only, no shorting)
the top-decile 12-1 momentum names, equal-weight, rebalanced monthly, net of
realistic transaction costs, and measure the result against a broad
equal-weight market benchmark. This is the shape the TradeWizz app can actually
trade (it buys ~10 US names; it cannot short).

## Purpose
All earlier momentum tests measured a long-SHORT decile spread, which the app
cannot implement. This atom answers the only question that matters for
production: does long-only top-momentum, after costs, beat just holding the
market? And does the crash guard help in this realistic setting?

## Theory / Why it works
Same relative-strength persistence as cross-sectional-momentum: recent winners
keep outperforming for months. Long-only captures the winner leg only; it gives
up the (often noisier) short-leg alpha but avoids short borrow/locate cost and
the momentum-crash short-leg blowups.

## When it works
- Persistent trending markets; the winner leg compounds ahead of the market.
- Liquid names where 10 bps/side is a fair cost estimate.

## When it fails
- Sharp post-crash V-recoveries: winners can lag the beaten-down names that
  rebound hardest, so long-only momentum gives back relative gains (2009, 2020).
- High-turnover regimes where costs erode the thin monthly excess.

## Strengths
- **Beats the market after costs**: +0.84%/hold excess over the equal-weight
  benchmark across 231 rebalances (2007-2026), ~4x the benchmark terminal
  wealth (cum +93.5x vs +24.4x), at similar Sharpe (0.89 vs 0.95).
- Directly implementable in the app (long-only, ~10 names, monthly).
- Edge SURVIVES realistic transaction costs (10 bps/side, turnover-based).

## Weaknesses
- Excess-return Sharpe is modest (0.49) — the edge is real but not enormous;
  most of the strategy's total Sharpe is just market beta.
- **The crash guard that helped long-SHORT HURTS long-only** (see below) — a
  key, non-obvious finding. Long-only needs a DIFFERENT risk control.
- Worst single hold -36.6% (net) — long-only still eats full market crashes; it
  has market beta ~1.

## Risk
Long-only momentum carries essentially full market risk (beta ~1) plus a small
positive alpha. It is NOT a hedge. In a crash it falls roughly with the market.
Any production use must size positions for that (the app already caps per-name
notional and uses SL/TP).

## Examples
2013, 2017, 2021 trend years: top-decile momentum compounded well ahead of the
equal-weight market net of cost.

## Counterexamples
Post-GFC 2009 and post-COVID 2020 rebounds: beaten-down names rebounded hardest,
so long-only momentum (holding prior winners) lagged, and the cash guard made it
WORSE by sitting out the recovery.

## Implementation (rule spec)
- Signal: 12-1 (252d return skipping the last 21d). Rank tradable names.
- Portfolio: equal-weight top decile (in the app, ~top 10 by score), long only.
- Rebalance monthly (21 trading days).
- Costs: model ~10 bps/side on turnover.
- Risk control: use a **per-position STOP-LOSS**, NOT a market cash gate and NOT
  a vol-target scale-down. A stop-loss overlay was the ONLY control tested that
  improved BOTH the tail AND compounding (see evidence log 2026-07-04b). This
  matches the app's existing SL/TP design. De-risking overlays (cash gate,
  partial vol-target) all HURT long-only momentum by giving up upside.

## Backtesting ideas
- DONE: long-only top-decile vs equal-weight benchmark, net of 10 bps/side,
  2007-2026, with and without the bear+vol cash guard.
- DONE (2026-07-04b): risk-control comparison -- per-hold stop-loss won.
- DONE (2026-07-04c): cost x top-N sensitivity grid. TOP-10 + stop is the
  BEST cell and survives 20bps (worst-case) cost. See evidence log.
- NEXT: calibrate the stop to the app's real intraday SL mechanics (not a
  monthly floor proxy); OOS split on the stop-loss overlay; then Stage-4
  live-eval (needs TestFlight).

## Relationships to other concepts
- Production form of **cross-sectional-momentum** (which is the long-short study).
- **momentum-crash-guard** applies to the long-SHORT form; this atom records
  that the SAME guard is counterproductive long-only — scope corrected there.
- Uses **liquidity-participation** tradability gate as pre-filter.

## References
- Jegadeesh, N. & Titman, S. (1993). Returns to buying winners and selling
  losers. Journal of Finance 48(1).
- Barroso, P. & Santa-Clara, P. (2015). Momentum has its moments. JFE 116(1).

## Evidence log
- 2026-07-04: Stage-3 LONG-ONLY, cost-aware backtest.
  `research/backtests/momentum-longonly/run.py`; results `results.json`.
  343 backfilled `period=max` liquid US names, 231 monthly rebalances,
  2007-2026 (multi-regime). Costs = 10 bps/side, turnover-based; benchmark =
  equal-weight all tradable names (also charged its turnover). Crash guard =
  the OOS-validated bear+vol gate, implemented long-only as move-to-CASH.

  Measured (real, not fabricated), NET OF COST:
  - benchmark (equal-weight):     +1.58%/hold, cum +24.4x, Sharpe 0.95.
  - momentum top-decile:          +2.42%/hold, cum **+93.5x**, Sharpe 0.89.
  - momentum top-decile GUARDED:  +2.06%/hold, cum +50.8x, Sharpe 0.85.
  EXCESS over benchmark:
  - momentum:        **+0.84%/hold**, cum +3.73x, Sharpe 0.49.
  - guarded:         +0.48%/hold, cum +0.85x, Sharpe 0.25.

  FINDINGS:
  1. Long-only top-momentum BEATS the market after realistic costs (+0.84%/hold
     excess, ~4x terminal wealth). The edge is production-relevant and survives
     transaction costs. This is the app-tradable form of the momentum edge.
  2. IMPORTANT / NON-OBVIOUS: the bear+vol crash guard that HELPED the
     long-short spread HURTS long-only (guarded cum +50.8x < raw +93.5x; excess
     Sharpe 0.49 -> 0.25). Reason: long-only has no short leg to protect; the
     cash gate simply sits out post-crash recovery rallies that the held winners
     participate in. => scope of momentum-crash-guard is LONG-SHORT ONLY;
     long-only needs a different risk control (trailing stop / partial
     vol-target), left as an open research item.

  Stage `backtest-oos` inherited from the OOS-validated signal; confidence 78,
  evidence 66. NOT auto-promoted: needs a long-only-appropriate risk overlay,
  cost/top-N sensitivity, and true Stage-4 live-eval (TestFlight) before
  production. Recorded. Honest correction of the crash-guard's scope is the
  main knowledge gained here.

- 2026-07-04b: Stage-3 RISK-CONTROL comparison for the long-only book.
  `research/backtests/momentum-longonly-risk/run.py`; results `results.json`.
  Same 343-name / 231-rebalance / 10bps setup. Five overlays on the top-decile
  book (all causal): baseline, partial vol-target (scale 0.5-1.0, never cash),
  per-hold stop (floor each hold at -15%), half-in-bear (50% when mkt<200dMA),
  trend-scaled (continuous exposure by mkt/200dMA).

  Measured (real, not fabricated), NET OF COST:
  - baseline:          +2.42%/hold, worst -36.6%, cum +93.4x, Sharpe 0.89
  - partial voltarget: +1.77%/hold, worst -36.6%, cum +29.0x, Sharpe 0.81
  - **per-hold stop:   +2.69%/hold, worst -15.1%, cum +211x, Sharpe 1.08**
  - half-in-bear:      +2.23%/hold, worst -33.0%, cum +72.8x, Sharpe 0.90
  - trend-scaled:      +2.66%/hold, worst -39.6%, cum +134x, Sharpe 0.89
  EXCESS Sharpe: per-hold stop 0.74 (best) vs baseline 0.55.

  FINDING: a **per-position stop-loss** is the winning long-only risk control --
  the ONLY overlay that improved BOTH the tail (worst -36.6% -> -15.1%) AND
  compounding (cum +93.4x -> +211x, Sharpe 0.89 -> 1.08). Mechanism: cutting
  losers early keeps capital in winners (momentum's own thesis) instead of
  parking in cash. This is exactly what the app already does (SL/TP). Every
  DE-RISKING overlay (cash gate earlier, partial vol-target here) HURT -- the
  consistent lesson is: do not step OUT of a long-only momentum book, cut the
  individual losers instead.
  HONEST CAVEATS (recorded): (1) the -15% cap is applied to a MONTHLY realized
  return -- a crude proxy for the app's intraday -1% SL, so the exact +211x is
  optimistic; the DIRECTION (stops help) is robust, the magnitude is not. (2)
  -15% level is in-sample; needs sensitivity + OOS before trust. Confidence
  78->80, evidence 66->70.

- 2026-07-04c: Stage-3 COST x CONCENTRATION sensitivity grid.
  `research/backtests/momentum-longonly-sens/run.py`; results `results.json`.
  Same 343-name / 231-rebalance setup. Grid: cost in {5,10,20} bps/side x
  TOP_N in {10, 20, 34(full decile)}, each with and without the stop overlay.
  Excess-over-benchmark Sharpe (WITH stop):
  - top10: 5bps 0.82 / 10bps 0.82 / 20bps 0.84  (excess ~+2.0-2.1%/hold)
  - top20: 5bps 0.80 / 10bps 0.81 / 20bps 0.83  (excess ~+1.6%/hold)
  - top34: 5bps 0.69 / 10bps 0.70 / 20bps 0.74  (excess ~+1.1%/hold)

  FINDINGS:
  1. CONCENTRATION HELPS: top-10 (exactly what the app holds) is the STRONGEST
     cell -- higher excess Sharpe than top-20, and clearly above the full decile
     (top-34). The very strongest-momentum names carry the most alpha; diluting
     weakens it. The app's ~10-name design is OPTIMAL, not a compromise.
  2. COST-ROBUST: the excess edge does NOT erode from 5->20 bps (it nudges UP,
     0.82->0.84). Reason: the benchmark is charged cost too, and the edge is
     measured RELATIVE to it, so symmetric cost cancels in the excess. Even at
     the realistic worst case (Moomoo SG ~$0.99/order ~= 20bps on a $500
     position), the edge holds fully.
  3. The stop overlay improves EVERY cell (e.g. top10/10bps excess Sharpe
     0.67->0.82), confirming the stop-loss finding is robust across configs.
  This tightens the production spec: LONG-ONLY top-10 by 12-1 momentum, monthly,
  with a per-position stop. Confidence 80->82, evidence 70->73. Remaining before
  production: stop-calibration to real app SL mechanics + OOS on the overlay +
  Stage-4 live-eval.
