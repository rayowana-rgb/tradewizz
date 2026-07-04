# TradeWizz Research Institute — Index

The AI Research Institute behind TradeWizz. Mission: turn verifiable knowledge
into a production-ready investment intelligence system. We optimize for
correctness, explainability, robustness, and maintainability — never speed.

**Binding rule:** no concept enters `backend/app/` (the production engine)
until it passes the four-stage gate in [`research/pipeline.md`](research/pipeline.md),
with **measured** evidence that it improves decision quality. We never fabricate
metrics or citations. Failed results are kept, not hidden.

## Data we actually have (as of 2026-07-04)
- Live OHLCV cache: ~1 trading year of **daily** bars per symbol
  (`period=1y, interval=1d`), window ~2025-07 .. 2026-07.
- US universe with daily data: ~12,270 symbols (10,310 with a shared calendar).
- Columns: Date, Adj Close, Close, High, Low, Open, Volume.
- Archive retention: 30 days (not a long-history source).
- **Hard limit:** ~1 year = a SINGLE market regime. Cross-sectional / relative
  claims are testable now; multi-regime Sharpe / true drawdown are NOT.
  Evidence scores are capped accordingly (see pipeline.md).

## Knowledge Atoms

| Atom | Stage | Confidence | Evidence | Verdict |
|------|-------|-----------|----------|---------|
| [Cross-Sectional Momentum (12-1)](research/atoms/cross-sectional-momentum.md) | **backtest-oos** | 80 | 68 | Multi-year 12-1 mean IC +0.025 (t 1.76); STAGE-4 OOS: TEST (2017-2026, unseen) mean IC +0.036 (t 1.67) -> edge stronger out-of-sample. First concept with a full 4-stage chain. Marginal significance; needs long-only variant + costs before production. |
| [Liquidity & Participation Score](research/atoms/liquidity-participation.md) | backtest | 80 | 40 | Tradability gate VALIDATED (19.3% of US universe non-tradable; illiquid names 6.5x fwd-ret variance). Signal-hygiene sub-claim (illiquidity lowers IC) REJECTED. Sound RISK pre-filter; awaits Stage-4 before wiring to risk_score. |
| [Short-Term Reversal (1-month)](research/atoms/short-term-reversal.md) | backtest | 62 | 30 | **REJECTED** on our data: IC strongly NEGATIVE (-0.09), monotonicity -0.94 -> the effect is short-term MOMENTUM, not reversal. Negative result, recorded. |
| [Short-Term Momentum (1-month)](research/atoms/short-term-momentum.md) | backtest | 32 | 40 | DEMOTED. 20-year OOS re-test (3-1 proxy) gave IC +0.0000, t 0.003 -> the 1-month continuation was a SINGLE-REGIME ARTIFACT of the 2025-26 trending window; averages to zero across history. NOT a production candidate. Retained as a cautionary example. |
| [Regime Guard (trend/vol state)](research/atoms/regime-guard.md) | backtest | 58 | 22 | Naive on/off gate REJECTED on 1y data (single crash). SUPERSEDED by momentum-crash-guard (multi-year, real crashes). |
| [Long-Only Momentum (production form)](research/atoms/momentum-long-only.md) | **backtest-oos** | 84 | 80 | App-tradable form (long-only, TOP-10, monthly, net of 10bps/side). BEATS market after costs (+0.84%/hold excess, ~4x wealth); top-10 concentration OPTIMAL; edge survives 20bps. CRITICAL CORRECTION (07-04d): realistic intraday sim shows the app's SL-1%/TP+3% config DESTROYS the edge (+235x -> -53%) -- a -1% stop is inside daily noise & +3% clips momentum's fat tail. Monthly momentum needs NO tight stop (let rebalance exit) or only a WIDE disaster stop. Earlier "stop wins" was a monthly-proxy artifact, SUPERSEDED. LEADING production candidate, with corrected exit rule. |
| [Low-Volatility (long-only, unlevered)](research/atoms/low-volatility.md) | backtest-oos | 30 | 55 | **REJECTED** standalone: long-only unlevered low-vol UNDERPERFORMS the market (excess t -3.42 FULL / -3.12 TEST). The academic low-vol edge needs shorting+leverage we don't have. KNOWLEDGE RETAINED: it's ~orthogonal to momentum (corr 0.24-0.49) and a 50/50 blend raised ABSOLUTE Sharpe above both books -- but with no standalone alpha it DILUTES momentum's significance (blend excess-t 1.06/1.30 < momentum's 2.94/2.62). Wrong blend partner; decorrelation method is reusable with an alpha-bearing partner. |
| [Momentum Crash Guard](research/atoms/momentum-crash-guard.md) | **backtest-oos** | 75 | 68 | Stage-3: vol-target cut worst -65.7%->-15.1%, bear+vol gate best Sharpe 0.58. STAGE-4 OOS (thresholds frozen on TRAIN<2017, applied blind to TEST>=2017): on unseen data both guards BEAT raw (bear+vol gate Sharpe 0.60 vs raw 0.40, worst -31% vs -65.7%). Guard generalizes. Marginal sig (t 1.83); tail reduced not removed. |

Legend — Stage: lit → logic → backtest → live-eval → prod.

## Framework (target)
Each atom feeds one or more TradeWizz Framework scores. None are production yet;
they are populated only by atoms that pass Stage 4.
- Trend, Momentum, Participation, Liquidity, Institutional, Volatility, Risk,
  Fundamental, Macro, ML, Confidence, Conviction, Expected Return, Expected
  Drawdown.

## Open research threads / next candidates
1. **Momentum-crash risk overlay** — the 6-1 inversion we measured is the exact
   failure mode; a volatility/regime guard is a prerequisite before momentum
   could ever be trusted. (lit → logic)
2. **Short-term reversal (1-month)** — the effect we deliberately skip; worth an
   atom in its own right and testable on our data. Given the 6-1 momentum
   INVERSION we found, short-term/medium reversal may be the stronger effect in
   this regime — high-priority next test.
3. **Low-volatility / defensive factor** — testable cross-sectionally on 1y; the
   6.5x variance gap we measured suggests volatility itself is highly
   dispersed and worth ranking.
4. Acquire **multi-year history** to lift the evidence ceiling above ~55 and
   test momentum-crash / regime behavior properly.

## Cross-atom findings (measured, 2026-07-04)
- **Horizon structure of this regime (2025-07..2026-07):** 1-month = STRONG
  momentum (continuation, |monotonicity| ~0.9); 6-month = INVERTED momentum
  (weak); 3-month = weakly positive momentum. My earlier guess of a
  'mean-reverting regime' was WRONG and corrected by the reversal test: the
  short horizon is strongly trend-continuing, NOT reverting.
- Illiquid US names carry ~6.5x the forward-return variance of liquid names,
  AND the liquidity gate STRENGTHENED the short-term momentum signal -> the
  liquidity pre-filter improves both risk AND signal cleanliness. Strong
  argument for making it mandatory.
- Net conviction: the most promising (but theoretically fragile) production
  candidate so far is SHORT-TERM (1-month) MOMENTUM behind a liquidity gate,
  pending out-of-sample and a regime guard. Nothing is production-ready yet.
- **LONG-ONLY production form tested** (2026-07-04, Stage 3, cost-aware): buying
  the top-decile 12-1 names long-only, net of 10bps/side, BEATS the equal-weight
  market by +0.84%/hold (~4x terminal wealth, cum +93.5x vs +24.4x) across
  2007-2026. The edge survives realistic costs and is directly app-tradable.
  **Non-obvious finding:** the bear+vol crash guard that HELPED long-short HURTS
  long-only (guarded cum +50.8x < raw +93.5x, excess Sharpe 0.49->0.25) because
  a cash gate just sits out post-crash recoveries the held winners join. Guard
  scope corrected to long-short only; new atom `momentum-long-only.md` (conf 78,
  ev 66). Open item: a long-only risk control (trailing stop / partial
  vol-target). This is now the leading PRODUCTION candidate.
- **DIVERSIFICATION TEST -- momentum + low-vol** (2026-07-04f, Stage 3): tested
  whether an orthogonal low-vol book lifts portfolio Sharpe via decorrelation.
  MIXED (honest): the decorrelation is REAL (corr 0.24-0.49) and a 50/50 blend
  raised ABSOLUTE Sharpe above both books (FULL 0.97>0.92/0.72; TEST 1.12>
  1.09/0.63) -- but low-vol has NO standalone alpha in a long-only unlevered
  book (excess t -3.42 FULL), so the blend DILUTES momentum's significant edge
  (blend excess-t 1.06/1.30 < momentum 2.94/2.62). => PURE MOMENTUM stays the
  better production candidate; low-vol REJECTED standalone (new atom). The
  decorrelation METHOD is validated -- reuse it with an alpha-bearing partner
  (value/quality). Momentum atom unchanged (blend did not beat it).
- **FINAL-SPEC OOS PASSES AT t>=2** (2026-07-04e, Stage 3b): OOS split on the
  corrected final spec (top-10 long-only 12-1, monthly, NO tight stop). TRAIN
  <2017 (GFC), TEST >=2017 (COVID+bull). EXCESS-over-benchmark: TEST +2.77%/hold
  **t 2.49** (>2, significant), Sharpe 0.82 vs TRAIN t 1.07 -- the edge did NOT
  decay OOS, it STRENGTHENED. FULL-sample excess t 2.70 -- the first long-only
  result in the program to cross t>=2. Absolute TEST: +4.69%/hold, cum +53.4x,
  Sharpe 1.06. The SL-8% disaster stop HURTS everywhere (excess t 2.70->1.08,
  negative in TRAIN) -> even a WIDE stop underperforms; correct spec is NO
  intraday stop, monthly rebalance is the exit. STRONGEST-evidenced, most
  production-ready concept in the institute; only Stage-4 live-eval remains.
  momentum-long-only conf 80->84, ev 76->80.
- **CRITICAL CORRECTION -- REALISTIC INTRADAY SL/TP** (2026-07-04d, Stage 3):
  replaced the crude monthly -15% floor with a true path-dependent intraday
  stop (daily adj HIGH/LOW, stop-first on tie, gap-at-open) -- the app's actual
  mechanic. RESULT: the app's live SL -1% / TP +3% config is CATASTROPHIC for a
  monthly momentum book -- turns +235x into **-53%**. A -1% stop sits inside
  one day's normal noise (stops out momentum names before the multi-week thesis
  plays out) and a +3% target clips the fat right tail momentum lives on. Even
  wide bands (SL8/TP24) never beat the no-stop baseline. => the 2026-07-04b
  "stop-loss wins" result was an ARTIFACT of the monthly floor proxy and is
  SUPERSEDED. Correct spec: monthly momentum uses NO tight intraday stop (let
  the monthly rebalance be the exit), at most a WIDE disaster stop. Also a real
  product flag: the app's tight swing SL/TP is INCOMPATIBLE with a monthly
  momentum feature. Honesty > completion -- a claimed strength was removed;
  knowledge increased. momentum-long-only conf 82->80, ev 73->76.
- **LONG-ONLY SENSITIVITY** (2026-07-04c, Stage 3): cost x concentration grid.
  (1) TOP-10 (exactly the app's ~10-name book) is the STRONGEST cell -- higher
  excess Sharpe than top-20 and clearly above the full decile (top-34). The
  app's concentration is OPTIMAL, not a compromise. (2) COST-ROBUST: the excess
  edge does not erode from 5->20 bps (nudges up 0.82->0.84) because the
  benchmark pays cost too and the edge is measured relative. Even at Moomoo SG's
  ~20bps worst case the edge holds. (3) the stop overlay helps EVERY cell.
  Production spec tightened: long-only top-10 by 12-1, monthly, per-position
  stop. momentum-long-only conf 80->82, ev 70->73.
- **LONG-ONLY RISK CONTROL SOLVED** (2026-07-04b, Stage 3): compared 5 overlays
  on the top-decile book. A **per-position STOP-LOSS** was the only one to
  improve BOTH the tail (worst -36.6%->-15.1%) AND compounding (cum +93.4x->
  +211x, Sharpe 0.89->1.08, excess Sharpe 0.55->0.74). De-risking overlays
  (cash gate, partial vol-target) all HURT. Lesson: don't step OUT of a
  long-only momentum book -- cut individual losers. This matches the app's
  existing SL/TP. Caveat: the -15% cap is a monthly proxy for the app's intraday
  -1% SL, so magnitude is optimistic though direction is robust. momentum-long-
  only atom conf 78->80, ev 66->70.
- **STAGE-4 OOS PASSED** (2026-07-04): true train/test split (TRAIN year<2017
  incl. 2008-09 GFC; TEST year>=2017 incl. 2020 COVID). 12-1 signal: TRAIN
  mean IC +0.0145 (t 0.78) vs **TEST +0.0356 (t 1.67)** -> edge STRONGER
  out-of-sample. Crash-guard thresholds FROZEN on TRAIN, applied blind to TEST:
  both guards beat raw on unseen data (bear+vol gate Sharpe 0.60 vs raw 0.40,
  worst -31% vs -65.7%). **First concept with a complete 4-stage evidence
  chain up to historical OOS.** Honest caveats: no stat reaches t>=2 (best 1.83),
  tail reduced not removed, this is historical OOS not live Stage-4, needs a
  long-only production variant + transaction costs. Both atoms -> stage
  `backtest-oos` (momentum conf 80/ev 68; guard 75/68). True Stage-4 live-eval
  still requires the app in the user's hands (TestFlight).
- **Momentum CRASH GUARD validated** (2026-07-04, Stage 3, 231 rebalances
  2007-2026): momentum crashes ARE manageable. **Vol-target** (Barroso-
  Santa-Clara) cut the worst rebalance from **-65.7% to -15.1%** (4x) and
  raised Sharpe 0.25->0.44. **Bear+vol gate** (Daniel-Moskowitz; OFF when market
  <200d MA AND vol in top tercile, ~16% of months) turned **crash-year
  cumulative return from -1.28 to +0.03** and gave the best full-sample Sharpe
  (0.58). Both DECISIVELY beat raw momentum. This SUPERSEDES the naive
  regime-guard (which failed only because 1y data had a single crash). New atom
  `momentum-crash-guard.md` (conf 72, evidence 55). Momentum + guard now needs
  a Stage-4 OOS split before production.
- **Multi-year momentum re-test DONE** (2026-07-04, ~343 liquid names, common
  calendar 2006-2026, ~20y, multi-regime): **12-1 is now the strongest-evidenced
  concept** -- mean IC +0.0247, IC t 1.76, spread +0.71%/hold, hit 58% across
  231 rebalances; RIGHT sign, marginally significant. Horizon ordering over 20y
  is **12-1 > 6-1 > 3-1** (IC 0.025 > 0.015 > 0.000) -- the OPPOSITE of the 1y
  finding, confirming classic momentum and DEMOTING short-term-momentum (its
  3-1 proxy IC is ~0 over 20y => single-regime artifact). Regime dependence is
  now visible: momentum CRASHED in 2009 (IC -0.15, spread -7%, textbook post-GFC
  crash) and 2023 (-8%); strong 2013/2017/2022/2024. Momentum confidence raised
  74->78, evidence 32->55. Still not auto-promoted: t<2, crash-guard mandatory,
  and Stage-4 needs a broader backfilled universe.
- **Multi-year backfill assessed & readied** (2026-07-04): feasibility CONFIRMED
  (AAPL `period=max` = 11,480 rows, 1980..2026 via the backend fetch path).
  Plan: backfill ONLY the liquid tradable sub-universe (top ~800 by ADV, index
  symbols excluded), ~29 min at <=14 req/30s, resumable, separate cache entry
  (does NOT overwrite 1y). Script + note in `research/backfill/`. NOT yet run
  (bulk Yahoo fetch awaits go-ahead). This unblocks momentum 12-1, crash
  calibration, regime-guard, and the >55 evidence ceiling.
- **Regime guard tested & the naive version REJECTED** (2026-07-04): momentum
  IC was state-dependent (higher when trending) but the tradable SPREAD was
  better in the off-regime, so a naive on/off gate would have hurt returns.
  One crash date (2026-03-27, tmb -17.4%) dominated tail risk -> crash-defense
  is a real, not theoretical, problem. **Only 7 rebalances survived the 100d
  warm-up on 1y data.** This is now the STRONGEST argument in the whole
  institute for acquiring MULTI-YEAR HISTORY: every fragile-signal question
  (momentum crash, regime calibration, evidence ceiling >55) is blocked by the
  single ~1y regime. Recommended next infrastructure step over any new atom.
