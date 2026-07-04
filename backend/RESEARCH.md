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
| [Cross-Sectional Momentum (12-1)](research/atoms/cross-sectional-momentum.md) | backtest | 74 | 32 | Backtested on 1y US data; edge WEAK & not significant (t≈0), 6-1 inverted. **Not promoted.** |
| [Liquidity & Participation Score](research/atoms/liquidity-participation.md) | backtest | 80 | 40 | Tradability gate VALIDATED (19.3% of US universe non-tradable; illiquid names 6.5x fwd-ret variance). Signal-hygiene sub-claim (illiquidity lowers IC) REJECTED. Sound RISK pre-filter; awaits Stage-4 before wiring to risk_score. |
| [Short-Term Reversal (1-month)](research/atoms/short-term-reversal.md) | backtest | 62 | 30 | **REJECTED** on our data: IC strongly NEGATIVE (-0.09), monotonicity -0.94 -> the effect is short-term MOMENTUM, not reversal. Negative result, recorded. |
| [Short-Term Momentum (1-month)](research/atoms/short-term-momentum.md) | backtest | 55 | 40 | Discovered empirically (sign-flip of the reversal test). Cleanest signal we have (|monotonicity|~0.9), stronger among tradable names. BUT contradicts academic prior + single regime -> low confidence, NO production without Stage-4 OOS + regime guard. |
| [Regime Guard (trend/vol state)](research/atoms/regime-guard.md) | backtest | 58 | 22 | Prerequisite gate for short-term momentum. IC IS state-dependent (0.10 on vs 0.01 off) BUT tradable spread was BETTER off-regime -> naive gate REJECTED. Only 7 rebalances; one crash date dominates. Needs multi-year data to calibrate. |

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
- **Regime guard tested & the naive version REJECTED** (2026-07-04): momentum
  IC was state-dependent (higher when trending) but the tradable SPREAD was
  better in the off-regime, so a naive on/off gate would have hurt returns.
  One crash date (2026-03-27, tmb -17.4%) dominated tail risk -> crash-defense
  is a real, not theoretical, problem. **Only 7 rebalances survived the 100d
  warm-up on 1y data.** This is now the STRONGEST argument in the whole
  institute for acquiring MULTI-YEAR HISTORY: every fragile-signal question
  (momentum crash, regime calibration, evidence ceiling >55) is blocked by the
  single ~1y regime. Recommended next infrastructure step over any new atom.
