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
   atom in its own right and testable on our data.
3. **Low-volatility / defensive factor** — testable cross-sectionally on 1y.
4. **Liquidity/participation score** — needed to avoid stale-price ranking that
   contaminates every cross-sectional signal.
5. Acquire **multi-year history** to lift the evidence ceiling above ~55.
