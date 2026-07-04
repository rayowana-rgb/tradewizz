---
title: Momentum Crash Guard (vol-target + bear/vol gate)
slug: momentum-crash-guard
stage: backtest
confidence: 72
evidence: 55
domains: [momentum, risk-management, factor-investing, quantitative-trading]
frameworks: [momentum_score, risk_overlay]
timeframe: position
regime: all
assets: [us-equities]
updated: 2026-07-04
---

## Definition
A risk overlay applied to a cross-sectional momentum signal that reduces
exposure in the states where momentum historically CRASHES, so the strategy
keeps its long-run edge while cutting its severe left tail. Two complementary
designs:
1. **Vol-target** (Barroso-Santa-Clara 2015): scale the momentum bet by
   `target_vol / realized_vol_of_the_strategy`. Purely reactive to the
   strategy's own turbulence; no crash prediction needed.
2. **Bear+vol gate** (Daniel-Moskowitz 2016 flavor): switch momentum OFF (or
   halve it) when the market is BELOW its 200d moving average AND market
   realized volatility is in its top tercile — the "panic-then-rebound" state
   where prior losers rebound hardest and momentum inverts.

## Purpose
The multi-year 12-1 momentum re-test proved a real edge (IC t 1.76 over
2006-2026) but with textbook crashes (2009 IC -0.15/spread -7%, 2023 -8%).
Momentum CANNOT go to production without a crash guard — the fat left tail is
the dominant risk. This atom is the mandatory gate on cross-sectional-momentum.

## Theory / Why it works
Momentum crashes are not random. After a market decline, the bottom-momentum
decile is full of beaten-down names; when the market rebounds, those names
snap back hardest, so being short/underweight them (relative to winners) loses
violently. This concentrates in high-volatility bear states. Barroso-Santa-Clara
show the strategy's OWN volatility is highly forecastable and spikes before
crashes, so vol-targeting mechanically de-risks in time. Daniel-Moskowitz show
the crashes cluster in bear + high-vol states, so a state gate catches them.

## When it works
- On negatively-skewed factors (momentum) whose bad months cluster in
  identifiable turbulent regimes.
- Multi-year horizons with at least a few crash episodes to justify the guard.

## When it fails
- Vol-target lags a truly instantaneous crash (it reacts to realized, not
  future, vol) — it shrinks the tail but does not remove it.
- The bear+vol gate can miss whipsaw crashes that occur while the market is
  still above its 200d MA, and can sit out some good recovery months (it is
  conservative by design).
- In calm, persistently trending regimes the guard is rarely active and adds
  little (and its cost/turnover is wasted).

## Strengths
- **Vol-target cut the worst rebalance from -65.7% to -15.1% (4x)** and raised
  full-sample Sharpe 0.25 -> 0.44.
- **Bear+vol gate turned crash-year cumulative return from -1.28 to +0.03**
  (crash damage essentially eliminated) and gave the best full-sample Sharpe
  (0.58) and highest total return, active only ~16% of months.
- Both are cheap, explainable, and use only information known at rebalance date
  (no look-ahead).

## Weaknesses
- Guards were CALIBRATED on the same 2006-2026 sample they are evaluated on
  (in-sample overlay). The mechanism is literature-backed, but the specific
  thresholds (200d MA, top-tercile vol, 2%/hold target) are not yet
  out-of-sample validated.
- Universe is only 343 liquid backfilled names; a broader universe may shift
  magnitudes.
- The gate's "off" months forgo any momentum gains in those months — an
  opportunity cost if a crash does not materialize.

## Risk
The guard reduces but does not eliminate tail risk. It must be presented as a
risk overlay, never as a guarantee. A user must understand that momentum still
has bad months; the guard makes the worst ones survivable, not absent.

## Examples
March-May 2009 (post-GFC rebound): raw momentum suffered its worst rebalance
(-65.7% spread). The bear+vol gate would have been OFF (market well below 200d
MA, vol in top tercile), avoiding the loss; vol-target would have scaled the bet
down sharply, capping the loss near -15%.

## Counterexamples
In a calm uptrend the guard is inactive and identical to raw momentum — it adds
nothing there, only in turbulence.

## Implementation (rule spec)
- Compute the realized momentum long-short spread series at each monthly
  rebalance (top decile minus bottom decile of 12-1 signal, tradable names).
- Vol-target: `scale = min(1.5, target_vol_per_hold / trailing_strategy_vol)`,
  trailing_strategy_vol = std of last ~6 realized spreads. Apply scale to the
  next month's exposure.
- Bear+vol gate: market proxy = equal-weight tradable-US return; level =
  cumprod; `bear = level < 200d MA`; `highvol = expanding-percentile(21d
  realized vol) >= 0.667`; if `bear AND highvol` -> set momentum exposure to 0
  (or 0.5 for the softer variant).
- Production recommendation (pending Stage-4): COMBINE — apply the bear+vol gate
  for crash avoidance AND vol-target for tail smoothing.

## Backtesting ideas
- DONE (see Evidence log): 231 rebalances, 2007-2026, both designs vs raw.
- NEXT (Stage-4): out-of-sample split (calibrate thresholds on 2007-2016,
  test 2017-2026) to confirm the guard is not overfit; re-run on a broader
  backfilled universe; add realistic transaction costs (the gate reduces
  turnover in bad months, vol-target may increase it).

## Relationships to other concepts
- MANDATORY overlay on **cross-sectional-momentum** (which is blocked from
  production until this guard is Stage-4 validated).
- Supersedes the naive **regime-guard** on/off classifier, which was REJECTED
  on 1-year data (single crash, could not calibrate). This atom is the
  crash-guard done right, on multi-year data with real crashes.
- Uses **liquidity-participation** as the pre-filter for the momentum spread.

## References
- Barroso, P. & Santa-Clara, P. (2015). "Momentum has its moments." Journal of
  Financial Economics 116(1). (Volatility-scaled momentum.)
- Daniel, K. & Moskowitz, T. (2016). "Momentum Crashes." Journal of Financial
  Economics 122(2). (Crashes cluster in bear/high-vol states.)
- Moskowitz, T., Ooi, Y. H. & Pedersen, L. (2012). "Time Series Momentum."
  Journal of Financial Economics 104(2).

## Evidence log
- 2026-07-04: Stage-3 backtest RUN on the backfilled `period=max` liquid US
  universe. Harness `research/backtests/momentum-crash-guard/run.py`; results
  `results.json`. 343 names, 231 monthly rebalances, 2007-02-28 .. 2026-05-11
  (multi-regime incl. 2008-09 GFC, 2020 COVID, 2022 bear). Bear+vol gate was
  active (OFF) ~16% of months.

  Measured (real, not fabricated):
  FULL SAMPLE (mean/hold, worst rebalance, cumulative sum, Sharpe proxy):
  - raw momentum:      mean +0.71%, worst **-65.7%**, sum +1.64, Sharpe 0.25,
    96/231 negative holds.
  - vol-target:        mean +0.40%, worst **-15.1%** (4x smaller tail),
    sum +0.92, Sharpe **0.44**.
  - bear+vol gate off: mean +1.25%, worst -31.4%, sum **+2.90**, Sharpe **0.58**
    (best), 78/231 negative holds.
  - bear+vol gate half: mean +0.98%, worst -32.9%, sum +2.27, Sharpe 0.42.

  CRASH YEARS ONLY (2008/09/20/22/23, n=60), where raw momentum LOSES:
  - raw momentum:      mean **-2.13%**, worst -65.7%, cumulative **-1.28**.
  - vol-target:        mean -0.35%, worst -15.1%, cumulative -0.21 (6x less loss).
  - bear+vol gate off: mean **+0.05%**, cumulative **+0.03** (crash damage
    essentially eliminated).
  - bear+vol gate half: mean -1.04%, cumulative -0.62.

  VERDICT: momentum crashes are manageable. The **bear+vol gate** gives the best
  full-sample Sharpe and turns crash-year losses to roughly flat; **vol-target**
  gives the tightest tail (-65.7% -> -15.1%). Both DECISIVELY beat raw momentum.
  This validates the crash-guard CONCEPT and directly answers the failure that
  blocked the naive regime-guard (which had only one crash on 1y data).
  Confidence 72, evidence 55. NOT yet production-final: the thresholds are
  in-sample; a Stage-4 out-of-sample split (calibrate 2007-2016, test 2017-2026)
  plus transaction costs are required before promoting momentum + guard to
  production. Recorded.
