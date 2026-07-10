---
title: Volume-Price Analysis + Wyckoff (mechanical cross-sectional proxy)
slug: vpa-wyckoff
stage: backtest       # lit | logic | backtest | live-eval | prod
confidence: 35        # theory is old & respected, but discretionary; our mechanization is a proxy
evidence: 20          # measured: mechanical VPA proxy shows NO cross-sectional edge; loses to momentum
domains: [volume-analysis, wyckoff, technical-analysis, quantitative-trading]
frameworks: []        # NONE yet — must pass the gate before it feeds any production score
timeframe: swing
regime: all
assets: [us-equities, etf]
updated: 2026-07-10
---

## Definition
Volume-Price Analysis (VPA) reads the *relationship* between price movement
("result") and the volume behind it ("effort"). The Wyckoff method frames a
security's life as a cycle — **Accumulation → Markup → Distribution →
Markdown** — driven by the "Composite Operator" (smart money) and detectable
through effort-vs-result anomalies (springs, up-thrusts, no-demand / no-supply
bars, climactic volume).

## Purpose
To buy where informed accumulation is evident (rising price *confirmed* by
rising volume, or a shakeout followed by strength) and to avoid names showing
distribution (up moves on falling volume, or up-thrusts rejected on high
volume). It is a *timing/confirmation* lens, not a return-forecasting factor.

## Theory / Why it works
Wyckoff's "law of effort vs result": a large effort (volume) that produces a
small result (price) — or vice versa — signals a change of hands. Genuine
demand shows *expanding* volume on up-bars and *contracting* volume on
pullbacks; genuine supply shows the opposite. If large operators are
accumulating, that footprint should precede markup.

## When it works
Liquid, single-name equities with honest volume (no heavy dark-pool masking);
swing-to-position horizons; range-to-trend transitions (the accumulation →
markup hinge is where it is designed to fire).

## When it fails
- **Discretionary by construction.** Wyckoff practitioners read *context* and
  chart shape; any mechanical encoding is a lossy proxy and will disagree with a
  human analyst.
- Volume semantics broke down structurally after ~2010 (fragmentation, dark
  pools, ETF-flow driven volume, algo/HFT). "Volume" is no longer a clean proxy
  for informed participation.
- Strong-trend / news-gap regimes: price runs without the tidy volume
  signature; VPA under-participates or gives late confirmations.
- No cross-sectional edge is *claimed* in the literature — VPA is per-name, not
  a ranking factor. Turning it into a top-decile rank is our stress test, not
  Wyckoff's intent.

## Strengths
- Intuitive, causal story (supply/demand) rather than a black box.
- Genuinely orthogonal information source to price-only momentum (uses volume).

## Weaknesses
- Not falsifiable in its native discretionary form; must be crudely mechanized.
- Volume data quality/meaning has degraded over the modern sample.
- Literature offers little robust, out-of-sample *quantitative* return evidence
  (unlike momentum, which has decades of peer-reviewed cross-sectional proof).

## Risk
If shipped as a stock picker it could systematically buy late-stage markups
mislabeled as accumulation, or miss clean momentum names that lack the textbook
volume signature. Drawdown character unknown until measured.

## Examples
Bullish (accumulation/markup): price closes in upper third of the bar's range
on above-average volume, part of a sequence of higher closes with expanding
up-volume vs contracting down-volume.

## Counterexamples
"No-demand rally" — price ticks up on shrinking volume; VPA correctly distrusts
it, but in a low-volume summer melt-up that same bar precedes further gains, so
the rule misses. Also 2020–2021 retail/meme volume made "high volume up-close"
fire on names that then collapsed (distribution disguised as demand).

## Implementation (rule spec)
Mechanical, cross-sectional, LONG-ONLY, to mirror the momentum production spec
exactly (same universe, calendar, costs, monthly hold, equal-weight top decile).
For each name at rebalance time t, using data strictly up to t (no look-ahead),
compute a **VPA-Wyckoff accumulation score** = sum of standardized signals:

1. **Effort-vs-result (trend confirmation).** Sign-agreement of price change and
   volume change over the lookback: up-days should carry above-median volume,
   down-days below-median. Score = (avg volume on up-days − avg volume on
   down-days) / avg volume, over the last 60 sessions.
2. **Close-strength.** Mean position of the close within each day's range
   ((Close−Low)/(High−Low)) over 20 sessions — demand closes bars strong.
3. **Volume-weighted trend (markup).** Price above its 20d & 50d volume-weighted
   average (proxy VWAP over the window) — confirms an established markup phase.
4. **Spring / shakeout bonus.** A recent (≤10d) new 20d-low intraday that closed
   back above the prior low's close on above-average volume = classic spring.
5. **Up-thrust / distribution penalty.** Recent bar making a new 20d high but
   closing in the lower third on high volume = up-thrust → subtract.

Rank names by the composite; go long-only equal-weight the top decile; rebalance
monthly (HOLD=21); costs 10 bps/side turnover-based. Benchmark = equal-weight all
tradable names (identical to the momentum test).

## Backtesting ideas
Run on the SAME max-history liquid US cache and the SAME engine as
`momentum-longonly` / `momentum-longonly-final-oos`, so the only variable is the
signal. Report net-of-cost benchmark, strategy, excess, Sharpe proxy, worst
hold, turnover, sample size. Then run the identical thing for momentum and put
them side by side. Data limit: our long history is a survivor-tilted liquid set;
treat absolute levels with caution, focus on the *relative* momentum-vs-VPA gap.

## Relationships to other concepts
- Complements price-only **cross-sectional-momentum** (adds volume information).
- Sibling to **liquidity-participation** (both use dollar-volume, different aim).
- Potential *overlay/confirmation* rather than a standalone ranking factor.

## References
- Richard D. Wyckoff, *The Richard Wyckoff Method of Trading and Investing in
  Stocks* (1931). (historical primary source)
- Tom Williams, *Master the Markets* (2005) — VSA formalization.
- Anna Coulling, *A Complete Guide to Volume Price Analysis* (2013).
- Note: none of the above provide peer-reviewed OOS cross-sectional return
  statistics; treat the *quantitative* claim as `unverified` pending our test.

## Evidence log
- 2026-07-10 (Stage-3, `research/backtests/vpa-wyckoff/run.py`): head-to-head vs
  12-1 momentum on the IDENTICAL engine (same 344-name max-history liquid US
  universe, same monthly rebalance calendar, same 10bps/side turnover cost, same
  equal-weight top-decile long-only construction). Window ~1981-08 -> 2026-01,
  231 monthly rebalances. Benchmark = equal-weight all tradable names.

  Net-of-cost cumulative return:
    * benchmark equal-weight ....... +2436%  (mean/hold 1.58%, Sharpe~0.95)
    * MOMENTUM top decile .......... +9345%  (mean/hold 2.42%, Sharpe~0.89)
    * VPA-WYCKOFF top decile ....... +2092%  (mean/hold 1.63%, Sharpe~0.74)

  Excess over benchmark (the honest edge test):
    * MOMENTUM ...... +0.839%/hold, excess_t = 2.17  (real, significant edge)
    * VPA-WYCKOFF ... +0.052%/hold, excess_t = 0.18  (indistinguishable from zero)

  Head-to-head (VPA minus momentum, per hold): -0.79%/hold, t = -2.18.
  VPA-Wyckoff UNDERPERFORMS momentum by a statistically significant margin, and
  even underperforms the naive equal-weight benchmark on cumulative return with a
  worse Sharpe. Its only mild positive: a shallower worst single-hold excess
  (-10.3% vs momentum's -23.1%) and it never beat cash-simple benchmark on risk.

  VERDICT: as a STANDALONE cross-sectional stock picker the mechanical VPA+Wyckoff
  proxy has NO measurable edge on our data and is strictly dominated by momentum.
  This is consistent with the literature: VPA/Wyckoff is a discretionary
  per-name timing/confirmation lens, not a ranking factor. It does NOT advance
  toward production as a picker. Possible future use ONLY as a confirmation
  overlay on momentum picks (untested; would need its own gate). Momentum remains
  the production candidate.

  Caveats (do not overclaim): survivor-tilted liquid set; "volume" semantics
  degraded post-2010; our mechanization is a lossy proxy of a discretionary
  method, so this refutes the *mechanical cross-sectional* form, not a skilled
  human Wyckoff read (which we cannot backtest).
