---
title: Regime Guard (trend / volatility state)
slug: regime-guard
stage: backtest
confidence: 58
evidence: 22
domains: [regime-detection, risk-management, volatility, momentum]
frameworks: [regime_score, risk_score, momentum_score]
timeframe: all
regime: all
assets: [us-equities, index]
updated: 2026-07-04
---

## Definition
A market-state classifier that labels the current environment as favorable or
unfavorable for a given strategy family, and gates that strategy on/off (or
scales its size) accordingly. Here, specifically: a guard that decides when the
fragile short-term-momentum signal may be trusted vs when it should be disabled
because a reversal/crash regime is likely.

## Purpose
The short-term-momentum atom is our cleanest signal but is theoretically
fragile: it contradicts the academic reversal prior and was measured in a
single trending regime. It MUST NOT run naked. This atom is the mandatory
prerequisite gate: it converts a fragile always-on factor into a conditional
one that is only active when the environment resembles the regime where it
worked. It also feeds risk_score generally.

## Theory / Why it works
- **Time-series (trend) momentum** (Moskowitz, Ooi & Pedersen 2012): markets in
  established up/down trends tend to continue; a simple trend filter (e.g.
  price vs its own trailing average, or sign of trailing 3-12 month return of a
  broad index) separates trending from choppy states.
- **Momentum crashes** (Daniel & Moskowitz 2016): cross-sectional momentum
  suffers rare, severe crashes concentrated in high-volatility rebound regimes
  (post-drawdown bounces where prior losers violently outperform). A volatility
  / market-state guard is the documented defense.
- **Volatility-managed / vol-scaled momentum** (Barroso & Santa-Clara 2015):
  scaling exposure inversely to recent realized volatility dramatically
  improves momentum's risk-adjusted returns and cuts crash risk. So realized
  vol of the market is a first-class regime input.
- **Breadth**: fraction of names above a trailing average measures whether a
  move is broad (healthy trend) or narrow (fragile).

## When it works
- Regime signals are most useful precisely where naive factors fail: at
  turning points and in high-volatility rebounds. A guard that cuts exposure
  there avoids the worst momentum drawdowns.

## When it fails
- **Whipsaw**: in choppy markets a binary on/off guard flips repeatedly, adding
  cost and cutting exposure right before recovery. Smoothing / hysteresis
  needed.
- **Lag**: trend and realized-vol signals are backward-looking; they turn off
  AFTER a crash begins, not before. They reduce, not eliminate, crash risk.
- **Single-regime data (ours)**: with ~1y we cannot observe enough crashes to
  calibrate the guard; our test caught ONE crash date (2026-03-27) which
  dominated the statistics. We can only test the WEAK claim that momentum
  strength varies with market state, not that the guard prevents a crash. Our
  run showed IC IS state-dependent but a naive on/off gate would have HURT
  tradable returns -- calibration needs far more data.

## Strengths
- Directly attacks the dominant failure mode of every momentum atom (crashes).
- Simple, transparent inputs (index trend, realized vol, breadth) from data we
  already have.
- Converts fragile signals into conditional, risk-aware ones.

## Weaknesses
- Lagging; cannot pre-empt a crash, only dampen it.
- Whipsaw / parameter sensitivity.
- Our data cannot validate the crash-prevention claim (no crash in-sample).

## Risk
A guard that is too loose fails to protect (false sense of safety); too tight
destroys the signal via whipsaw and cost. Mis-calibration is itself a risk.

## Examples
Market index above its 100-day average AND realized 21d vol below its median
-> "risk-on / trending" -> allow short-term momentum. Index below average with
elevated vol -> "risk-off" -> disable or halve exposure.

## Counterexamples
A sharp V-shaped bottom: the guard stays "risk-off" through the initial rebound
(lag) and misses the strongest momentum days. This is the accepted cost of the
insurance.

## Implementation (rule spec)
Compute a proxy market series (equal-weight mean daily return of the liquid
universe, or a broad index if available). Then:
- trend_state = 1 if proxy_price > trailing 100d average else 0
- vol_state = 1 if trailing 21d realized vol <= trailing median of realized vol
  else 0
- regime_on = trend_state AND vol_state (allow momentum), with hysteresis
- Downstream: momentum_score exposure = full when regime_on, 0 (or half) else.
- Report factor performance conditioned on regime_on vs regime_off.

## Backtesting ideas
On our ~1y US data (weaker, testable claim only):
1. Build the equal-weight market proxy and its regime label per date.
2. Split the short-term-momentum rebalances into regime_on vs regime_off dates.
3. Compare momentum IC / decile spread in each state. Hypothesis: the momentum
   edge is CONCENTRATED in regime_on dates and weaker/absent in regime_off.
4. Report honestly: single regime, few off-dates -> suggestive at best.

## Relationships to other concepts
- **Gates** short-term-momentum (mandatory prerequisite before production).
- Feeds **risk_score**.
- Complements **liquidity-participation** (liquidity = which names; regime =
  when to act at all).
- Directly addresses the crash failure mode noted in cross-sectional-momentum.

## References
- Moskowitz, T., Ooi, Y.H. & Pedersen, L.H. (2012). "Time series momentum."
  Journal of Financial Economics 104(2).
- Daniel, K. & Moskowitz, T. (2016). "Momentum crashes." Journal of Financial
  Economics 122(2).
- Barroso, P. & Santa-Clara, P. (2015). "Momentum has its moments." Journal of
  Financial Economics 116(1).

## Evidence log
- 2026-07-04: Stage-3 backtest RUN. Harness
  `research/backtests/regime-guard/run.py`; results `results.json`. 9,810 US
  symbols, 2025-07-03..2026-07-02. Proxy = equal-weight mean daily return of
  tradable names; regime_on = (level > 100d MA) AND (21d realized vol <=
  expanding-median vol). regime_on covered only 22.7% of days. Only 7
  rebalances survived the 100d trend warm-up (3 on / 4 off). Measured (real):

    regime_on (3):  mean IC 0.104; top-minus-bottom -0.0003/hold; hit 33%.
    regime_off (4): mean IC 0.010; top-minus-bottom +0.0182/hold; hit 75%.
    per-rebalance: 2026-03-27 was a crash date (IC -0.307, tmb -17.4%) that
    dominates the risk; trend was already off there but the guard did not
    prevent it entering the sample cleanly.

  VERDICT: my specific guard definition is REJECTED as a production gate on
  this data. IC (ranking consistency) WAS higher in regime_on (0.104 vs 0.010),
  supporting 'signal is state-dependent'. BUT the TRADABLE spread was BETTER in
  regime_off (+1.82% vs -0.03%), so a naive on/off guard would have DISABLED
  momentum during its best stretch -- the opposite of the intended protection.
  Sample far too small (7 rebalances) for any conclusion; one crash date
  (2026-03-27) dominates. HONEST TAKEAWAYS: (1) momentum IC is state-dependent
  (supports the concept); (2) a single crash dominates tail risk, confirming
  crash-defense is a real problem (Daniel-Moskowitz), NOT theoretical; (3) our
  ~1y single-regime data is TOO THIN to calibrate a trustworthy guard -- this
  is the clearest case yet for acquiring multi-year history. Stays
  stage=backtest, confidence 58, evidence 22. NOT production-ready; short-term
  momentum therefore also stays blocked from production (its prerequisite guard
  is unproven).
