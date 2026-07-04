# Production Candidate: Long-Only Cross-Sectional Momentum

**Status as of 2026-07-04:** Stage-3b (`backtest-oos`) COMPLETE and PASSED at
t >= 2 out-of-sample. Only Stage-4 (`live-eval`) remains, and it is BLOCKED on
getting the app into the user's hands via TestFlight.

This is the single decision document consolidating the full 4-stage evidence
chain. All numbers below are from real backtests recorded in `research/` -- none
are fabricated. Where a test overturned an earlier claim, the correction is kept
on the record (see "What we rejected").

---

## 1. The production spec (what we would ship)

- **Universe:** liquid US equities. Tradability gate: median 63d dollar-volume
  ADV >= $100k, <= 20% near-zero-volume days, >= ~6-12 months of clean history.
- **Signal:** cross-sectional **12-1 momentum** = trailing 252-day total return,
  **skipping the most recent 21 trading days** (avoids short-term reversal).
- **Portfolio:** **long-only, equal-weight top-10** by the signal.
- **Rebalance:** **monthly** (~21 trading days).
- **Exit rule:** **NO tight intraday stop.** The monthly rebalance IS the exit.
  A wide "disaster" stop (>= 8%) is optional tail insurance but HURTS returns in
  backtest, so the default spec is genuinely no intraday stop.
- **Costs assumed:** ~10 bps/side (round-trip on turnover). Result is robust to
  20 bps/side.
- **Beta:** ~1.0 (this is a long-only equity book, not market-neutral).

### Three evidence-backed refinements (optional)
1. **Ranking upgrade -- residual (beta-adjusted) momentum.** Ranking by the
   market-residual of 12-1 momentum beat raw 12-1 excess in every split
   (TEST excess-t 3.03 vs 2.62). Small OOS boost, no other change. Candidate
   swap, pending Stage-4.
2. **Tail-smoothing blend -- 50/50 12-1 + 6-1.** Slightly higher significance
   and a tamer worst drawdown than either horizon alone. Modest; not a new pillar.
3. **Crash-recovery overlay -- regime-switched reversal tilt (2026-07-04j).**
   When the equal-weight market is below its 200d SMA (~18% of periods), tilt
   60/40 momentum/long-term-reversal; otherwise 100% momentum. On the FULL
   sample this IMPROVES every metric vs pure momentum -- excess-t 3.25 vs 2.92,
   Sharpe 0.75 vs 0.68, worst-DD -14.7% vs -21.3% -- with big crisis-regime
   drawdown protection (TRAIN worst-DD -8.6% vs -21.3%). HONEST trade-off: a
   mild OOS-bull cost (TEST excess-t 3.04 vs 3.23), and the large crisis gain
   leans on the single 2008-09 recovery. The FIRST diversification structure
   that does not dilute momentum. Optional risk-reduction overlay, pending
   Stage-4. See `research/backtests/momentum-reversal-tilt/`.

---

## 2. The 4-stage evidence chain

### Stage 1 -- Literature (`lit`)
Cross-sectional momentum is one of the most replicated anomalies (Jegadeesh-
Titman 1993; Asness-Moskowitz-Pedersen 2013). Skip-a-month convention avoids the
1-month reversal effect. Recorded in `research/atoms/cross-sectional-momentum.md`.

### Stage 2 -- Logic (`logic`)
The signal is economically motivated (under-reaction / slow information
diffusion) and mechanically simple: rank, take the top decile, hold a month.
Liquidity/tradability gate ensures the names are actually investable at the
user's size ($500/position, ~10 names).

### Stage 3 -- Historical backtest (`backtest`)
- **Multi-year (~20y, 343 names, 231 rebalances):** 12-1 mean IC +0.0247
  (t 1.76), long-short spread +0.71%/hold, hit-rate 58.4%. Right sign,
  meaningful magnitude. `research/backtests/momentum-multiyear/`.
- **Long-only, cost-aware:** top-momentum long-only BEATS the market after
  realistic 10 bps costs. `research/backtests/momentum-longonly/`.
- **Sensitivity grid (cost x concentration):** top-10 optimal; excess Sharpe
  ~0.82 stable across 5/10/20 bps. `research/backtests/momentum-longonly-sens/`.

### Stage 3b -- Out-of-sample split (`backtest-oos`)
- **Final-spec OOS (TRAIN <2017 / TEST >=2017):** excess-over-benchmark
  **TEST t 2.49** (Sharpe 0.82) vs TRAIN t 1.07 -- the edge STRENGTHENED
  out-of-sample. FULL excess t 2.70. First long-only result to cross t >= 2 OOS.
  `research/backtests/momentum-longonly-final-oos/`. This is the strongest
  historical evidence in the institute to date.

### Stage 4 -- Live evaluation (`live-eval`) -- **NOT DONE (BLOCKED)**
Requires the app in the user's hands via TestFlight to measure real, forward,
paper-or-live decision quality. See section 5.

---

## 3. The critical correction (why the exit rule is what it is)

An earlier, crude monthly "-15% floor" proxy suggested a stop-loss HELPED. A
proper path-dependent **intraday** SL/TP simulation OVERTURNED that:
- The app's configured swing exit (SL -1% / TP +3%) turns a +235x no-stop
  backtest into **-53%** -- it chops the strategy to death.
- Every tight SL/TP band destroys the edge; even a wide 8% disaster stop reduces
  return.
`research/backtests/momentum-longonly-intraday-stop/`.

**Consequence (product flag):** the app's tight SL -1% / TP +3% swing config is
PROVEN INCOMPATIBLE with a monthly momentum strategy. Any production momentum
feature MUST use its own loose / no-stop exit -- do not reuse the swing exit.

---

## 4. What we rejected (kept so we don't repeat it)

The 4-stage gate did its job: it killed weak ideas with evidence.

- **Low-volatility (standalone):** no alpha in a long-only unlevered book
  (excess-t -3.42 FULL / -3.12 TEST, significantly NEGATIVE). The academic edge
  (BBW / Frazzini-Pedersen BAB) needs long-low-beta/short-high-beta + leverage
  we don't have. REJECTED standalone; ~orthogonal to momentum (corr 0.24-0.49),
  so the decorrelation METHOD was retained for reuse. `atoms/low-volatility.md`.
- **6-1 as a diversifier:** alpha-bearing but too CORRELATED with 12-1 (0.87),
  ~half the names shared. Blend lift is modest (kept only as a tail-smoother).
- **Residual momentum as a diversifier:** hypothesis "beta-adjusted = more
  orthogonal" REFUTED -- corr 0.91 (higher than 6-1), 7.5/10 names shared. It IS
  a modestly stronger standalone signal (kept as the ranking-upgrade refinement),
  but NOT a diversifier. `atoms/residual-momentum.md`.
- **Long-term reversal as a blend partner:** FIRST truly orthogonal partner
  (corr 0.34-0.46) but alpha is WEAK & REGIME-DEPENDENT (TRAIN/GFC t 1.66, TEST
  t 0.28), so a 50/50 blend DILUTES momentum. `atoms/longterm-reversal.md`.
- **Crash-guard (bear+vol cash guard):** HELPS long-short, HURTS long-only.
  Scope corrected to long-short only.
- **Short-term reversal / short-term momentum / naive regime-guard:** did not
  clear the bar.

**Two distinct decorrelation-failure modes are now on record:** a partner can
fail by being too CORRELATED (6-1, residual) or by having WEAK/regime-dependent
alpha (low-vol, reversal). We never found a partner that is BOTH strongly
alpha-bearing AND genuinely orthogonal -- which is itself an important, honest
conclusion: **pure momentum stands on its own; blending has not improved it.**

RESOLVED (2026-07-04j): the CONDITIONAL crash-recovery tilt hypothesis was
TESTED and CONFIRMED -- a regime-switched (200d-SMA) 60/40 overlay improves
full-sample excess-t, Sharpe AND worst-DD vs pure momentum, with a mild
OOS-bull cost. Promoted from "hypothesis" to optional refinement #3 above. This
is the one diversification idea that did NOT dilute momentum -- because it only
engages reversal during market stress, exactly when momentum is weakest.

---

## 5. What remains: Stage-4 live-eval (the only gap)

Everything historical points one way; the missing piece is FORWARD evidence of
real decision-quality improvement. That requires the app on the user's device.

**Blocker:** the iPhone dev build expired ("TradeWizz is no longer available").
Migration path is TestFlight. User has PAID for the Apple Developer Program; the
remaining step is creating an **Apple Distribution** certificate in Xcode
(Settings > Accounts > team 9D4M3NN778 > Manage Certificates > + > Apple
Distribution), then re-exporting the IPA and creating/confirming the App Store
Connect app record for `com.tradewiz.tradewiz`. Archive (build 7) already
succeeded; only the Distribution cert + upload remain.

**Once live:** run a forward paper/live evaluation of the top-10 monthly
momentum book vs the user's current discretionary book, measuring realized
decision quality (hit-rate, excess return, drawdown) -- the actual Stage-4 metric
the institute exists to produce.

---

## 6. One-line verdict

**Long-only top-10 12-1 momentum, monthly, no tight stop, ~10 bps/side** is the
institute's strongest-evidenced production candidate: it passes literature,
logic, historical backtest, and out-of-sample (excess TEST t 2.49) with a
corrected exit rule. It is READY for Stage-4 the moment TestFlight unblocks live
evaluation. Diversification was explored thoroughly and did not improve it;
pure momentum stands on its own.
