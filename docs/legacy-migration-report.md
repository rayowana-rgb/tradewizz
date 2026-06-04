# Legacy `bot9.py` → FastAPI Backend — Migration Report

**Date:** 2026-06-04
**Scope:** Analysis only. No code was modified. This is the plan that should
precede any migration work.

Sources compared:
- Legacy: `legacy_bot/bot9.py` (2,839 lines, Telegram bot + Flask, IDX-only)
- Current: `backend/app/{engine,indicators,mock_data,models,universe,cache}.py`
  (FastAPI, multi-market IDX/HKEX/KOSPI/KOSDAQ)

---

## 0. Executive summary

The legacy bot is a single 2.8k-line script mixing Telegram handlers,
subscription/billing, a Flask app, ~10 rule-based screeners, a RandomForest
profit classifier, an LSTM price predictor, and a PPO/TD3/SAC reinforcement-
learning trader. The current FastAPI backend has cleanly re-implemented the
**screener taxonomy and indicators in pure pandas/numpy**, but with
**simplified rules** and **none of the ML**.

The highest-value, lowest-risk migration is to **port the legacy rule logic
faithfully** (the categorizers are currently approximations) and add the
**RandomForest profit probability** + **backtest stats**, which are
deterministic, testable, and directly useful to the app. The RL trader and
LSTM should be treated as a separate, optional research track — they are heavy,
non-deterministic, and not required by the mobile app's current contract.

---

## 1. Extracted legacy components (inventory)

### 1.1 `analyze_stock()` (bot9.py:1545)
Per-symbol deep analysis. Flow:
1. `fetch_stock_data` → `prepare_data` (full indicator set).
2. **Trains a fresh RL model per call** (`train_reinforcement_model`, 70/30
   split) — PPO/TD3/SAC over a custom Gym env.
3. Predicts an action (Buy/Sell/Hold) + confidence from the action magnitude.
4. Computes lots to trade from user balance, immediate/major support &
   resistance (rolling 10/50 min-max), Sharpe ratio, model net profit.
5. Returns a Telegram-formatted Markdown string (Rupiah formatting).

> Maps to the backend's `/analyze/{symbol}` conceptually, but the backend's
> `analyze()` is indicator-based, not RL-based.

### 1.2 `analyze_screened_stocks()` (bot9.py:2312)
Post-screening refinement. Flow:
1. Pulls previously screened symbols by category from an in-memory cache
   (`bullish/scalping/accumulation/ara_hunter/swing_trade/short_candidate`).
2. Batches (size 5). Per symbol: `prepare_data`, then computes
   **strategy-specific buy/sell signals** (momentum / scalping / accumulation),
   dynamic **trailing-stop %** from ADX, **support/resistance**.
3. **RandomForest profit classifier** per symbol (`train_profit_model` /
   cached `rf_models/model_<sym>.pkl`) → profit probability.
4. Special handlers: ARA-hunter continuation, swing dead-cross/green-flip,
   short-sell detection, "frequent trading" boost.
5. Builds a recommendation string + `buy_reasons` list.

> This is the richest "analysis" logic in the legacy bot and the best template
> for a real `/analyze` response.

### 1.3 Indicator calculations (`prepare_data`, bot9.py:219)
Computed via **pandas_ta + TA-Lib**:
- Moving averages: `SMA_20`, `SMA_50`, `SMA_200`, `EMA_5` (and `EMA_9/EMA_21`
  referenced by scalping but **not actually computed** — a latent bug).
- Oscillators: `RSI(14)`, `Williams_%R(14)`, `Momentum(10)`, `Stoch_K/D`
  (momentum variant).
- Trend/vol: `MACD` + `MACD_Signal` + `MACD_Histogram` (12/26/9), `ATR(14)`,
  `ADX(14)`, Bollinger Bands(20,2).
- Volume/flow: `OBV`, `VWAP`, `CMF(20)`, `Accum_Dist` (A/D line), `Volume_Avg(20)`.
- Candlesticks (TA-Lib): Doji, Hammer, Engulfing, ShootingStar, Harami,
  HaramiCross.
- Support/resistance: rolling 10/50 min-max.
- Extras: `Market_Phase` (MA50 vs MA200), event flag (>2% move), augmented
  close (noise) — these are ML-feature plumbing, not user-facing.

### 1.4 Screener categories (legacy)
From `screened_stocks_cache` / `screen_momentum_stocks` (bot9.py:875):
`bullish, bearish, scalping, accumulation, pullback, backdoor_candidate,
turnaround, ara_hunter, short_candidate, frequently_traded, swing_trade` plus
standalone `sleeping_giants`, `insider_activity`, `silent_accumulation`.

Liquidity gates: general `value_traded ≥ Rp 2B`; silent-accum `≥ Rp 500M`;
several strategies use their own thresholds (Rp 5B/10B). **All IDX-specific.**

### 1.5 Per-category logic (exact legacy rules)

- **accumulation** (`screen_accumulation`, :2730): `len≥35`; A/D > 30-day mean
  ×1.1 **and** OBV > 30-day mean **and** Volume > 30-day mean ×1.2; price not
  exploded (`Close < SMA_50 ×1.15`); `value_traded ≥ Rp 10B`.
- **accumulation_silent** (`screen_silent_accumulation_candidates`, :2765):
  fetches its own 3-month data; `Close < 100`; `vol_3/vol_20 > 2`; |3-day price
  change| < 2%; `CMF > 0`; OBV 3-day diff sum > 0.
- **pullback** (`screen_pullback`, :636): SMA50>SMA200; Close>SMA200;
  Close<SMA20; 40<RSI<60; MACD>0 but `< MACD_Signal`; Volume < prev Volume.
  (Requires **all** criteria.)
- **turnaround_multibagger** (inline, :950): `value_traded ≥ Rp 500M`;
  `Close < 250`; Close>MA20>MA50; `vol_3/vol_20 > 1`; `CMF>0`; OBV 3-day diff
  sum > 0; `30<RSI<60`.
- **ara_hunter** (inline, :980): `Close ≥ prev×1.06` (near auto-reject-atas);
  `Close ≥ High×0.98`; `Volume > 10-day mean ×3`; `RSI>70`; `MACD>Signal`;
  A/D & OBV rising; `Close>SMA_20`; `nominal_value ≥ Rp 5B`.
- **frequently_traded** (inline, :1025): `Volume > 20-day mean ×2` **and**
  `nominal_value > Rp 10B`.
- **short_candidate** (`screen_short_candidates`, :855 + inline :1003):
  `RSI>70` and falling; `MACD<Signal`; `MACD_Histogram<0`; `Close<SMA_20`;
  `Volume > 10-day mean ×1.5`; OBV & A/D falling.
- **bullish** (`screen_bullish`, :653): 11 weighted criteria, needs **≥8** —
  price>SMA50, SMA50>SMA200×1.01, RSI rising & >55, MACD crossover, near BB
  upper, strong candle, volume surge, OBV/AD rising, ADX>18/25.
- **bearish** (`screen_bearish`, :704): 9 criteria, needs **≥7** — actually an
  *early reversal* detector (RSI divergence, near support, etc.).
- **scalping** (`screen_scalping_stocks`, :757): 9 criteria, needs **≥9** (all)
  with an exit guard — uses **EMA_9/EMA_21 which are never computed** (latent
  bug, effectively always fails that sub-check).
- **swing_trade** / **backdoor_candidate** / **sleeping_giants** /
  **insider_activity**: present in legacy, **not in the app taxonomy**.

### 1.6 ML / RandomForest (bot9.py:2206–2234)
- `label_profitable_signals`: forward-N-day return > threshold → binary label.
- `train_profit_model`: `RandomForestClassifier(100)`, 80/20 no-shuffle split,
  features = `[RSI, MACD, MACD_Signal, MACD_Histogram, VWAP, SMA_20, SMA_50,
  SMA_200, OBV, Accum_Dist, ADX, ATR, Volume]`, persisted to `rf_models/`.
- Used in `analyze_screened_stocks` to print a **profit probability**.

### 1.7 Backtest (bot9.py:2235–2311)
- `generate_historical_signals(df, signal_type)`: replays momentum/scalping/
  accumulation buy rules across history → 0/1 signal series.
- `backtest_signals(...)`: forward-N-day returns → `{n_signals, avg_return_%,
  win_rate_%, max/min_return_%, signal_dates, all_returns}`.

### 1.8 Reinforcement learning + LSTM (heavy)
- `MomentumTradingEnv`, `LSTMStockTradingEnv` (Gym), `train_reinforcement_model`
  (PPO/TD3/SAC, VecNormalize), `evaluate_model`, `plot_trading_dashboard`.
- `train_lstm_model` / `predict_next_days` (Keras/TF LSTM, MinMax scaler).
- Heavy deps: `stable_baselines3`, `gymnasium`, `tensorflow/keras`, `talib`.

### 1.9 Non-analytics (bot9.py)
Telegram handlers, Flask `create_app`, subscription/billing, API-key
management, SQLite user tables, Rupiah formatting, visualization PNGs.

---

## 2. What ALREADY EXISTS in the FastAPI backend

| Capability | Legacy | Current backend | Notes |
|---|---|---|---|
| OHLCV fetch | `fetch_stock_data` (IDX `.JK`) | `_yf_fetch` + suffix map (.JK/.HK/.KS/.KQ) | Backend is **multi-market**; cached + single-flight + timeout. |
| RSI(14) | pandas_ta | `indicators.rsi` (Wilder) | ✅ pure-python, no TA-Lib. |
| EMA | `EMA_5` | `ema(20)`, `ema(50)` | Different spans. |
| SMA | 20/50/200 | `sma(200)` only | **Missing SMA20/SMA50** as explicit outputs. |
| MACD | talib 12/26/9 | `indicators.macd` (line/signal/hist) | ✅ + `macd_hist_prev`. |
| ATR | talib(14) | `indicators.atr` (Wilder) + ATR% | ✅. |
| Volume ratio | rolling means inline | `indicators.volume_ratio(20)` | ✅. |
| Category taxonomy | 10+ categories | 10 categories (enum) | ✅ names match the 10 app categories. |
| `categorize()` | per-function rules | `engine.categorize` (approximation) | ⚠️ **rules differ** from legacy (see §3). |
| Signal + score | strategy-specific | `_signal_and_score` (weighted 0–100) | New synthesis; not in legacy. |
| Screen orchestration | `screen_momentum_stocks` (serial) | `engine.screen` (parallel, paginated, filtered) | Backend is **better engineered**. |
| Universe | `symbols.xlsx` (IDX) | `data/universe/*.csv` (4 markets) | ✅ generalized. |
| Mock fallback | none | per-symbol deterministic fallback | New; keeps API 200. |
| HTTP API | Flask stub + Telegram | FastAPI `/v1/...` + tests | ✅ clean, typed, CORS. |

**Indicators present:** RSI, EMA20, EMA50, SMA200, MACD(+hist,+prev), volume
ratio, ATR, ATR%.

---

## 3. What is MISSING (gaps vs legacy)

### 3.1 Indicators not yet computed
- **SMA_20, SMA_50** (explicit) — needed by almost every legacy rule.
- **OBV**, **Accum/Dist (A/D)**, **CMF** — the core "smart money / accumulation"
  signals; **accumulation, ara_hunter, turnaround, short_candidate all depend
  on them**. Their absence is why the current categorizers are approximations.
- **VWAP** — used by scalping/momentum buy signals.
- **ADX** — trend-strength gate (bullish, swing, trailing-stop sizing).
- **Bollinger Bands** — scalping/bullish breakout proximity.
- **Williams %R, Momentum, Stochastic** — minor; momentum/legacy features.
- **Candlestick patterns** — not used by the 10 categories; low priority.

### 3.2 Category rule fidelity (current = approximation)
The current `categorize()` uses EMA20/EMA50/SMA200/MACD-hist/vol-ratio/ATR%
heuristics. The legacy rules are materially different and richer:
- accumulation/silent: **OBV+A/D+CMF** based (backend uses MACD-hist+vol).
- ara_hunter: **price≥+6%, near-high, vol×3, A/D & OBV rising, value≥Rp5B**
  (backend uses just RSI≥70 + vol-ratio≥2).
- turnaround: **price<250, MA20>MA50, CMF>0, OBV up, value≥Rp500M** (backend
  uses `close < SMA200×0.7`).
- pullback/short_candidate: backend lacks OBV/A-D/SMA20 confirmation.
- **No liquidity gates** (legacy filters by `value_traded` in IDR). Backend
  screens every universe symbol regardless of turnover.

### 3.3 Analysis depth (`/analyze`)
- No **support/resistance**, **trailing-stop**, **buy_reasons**, or
  strategy-specific buy/sell signals. Current `/analyze` returns a synthesized
  signal/score + generic highlights.

### 3.4 ML & backtest
- **RandomForest profit probability** — **missing** (deterministic, valuable).
- **Backtest stats** (`backtest_signals`) — **missing** (deterministic,
  valuable, great for an app "edge" panel).
- **RL trader / LSTM predictor** — **missing** (heavy, non-deterministic).

### 3.5 Categories in legacy but not in app taxonomy
`swing_trade`, `backdoor_candidate`, `sleeping_giants`, `insider_activity`.
Decision needed: extend taxonomy or drop.

---

## 4. What should be migrated FIRST (recommended order)

Prioritized by **value ÷ risk**. Each step is independently shippable and
testable with synthetic OHLCV (no network), consistent with the existing test
strategy.

**Phase 1 — Indicator parity (foundation). ✅ DONE (2026-06-04).** Added
pure-pandas `OBV`, `A/D`, `CMF`, `VWAP`, `ADX`, `SMA_20`, `SMA_50`, Bollinger
Bands, plus `volume` and `value_traded` to `indicators.py`, surfaced as **new
keys only** in `compute_all` (existing keys/values untouched). No TA-Lib. No
category/scoring/API-contract change. 13 new unit tests on synthetic data;
backend 84 passed, Flutter 25 passed. *Unlocks faithful rules in Phase 2.*

**Phase 2 — Faithful category rules. ✅ PARTIAL DONE (2026-06-04).** Migrated
`accumulation, accumulation_silent, pullback, turnaround_multibagger,
ara_hunter, frequently_traded, short_candidate` from legacy thresholds
(OBV/A-D/CMF/SMA20-50/VWAP/rolling-volume based) into `engine.categorize`,
with per-market liquidity/price scaling (`_value_floor`/`_cheap_price`; IDX keeps
legacy IDR figures, HKEX/KOSPI/KOSDAQ scaled). `compute_all` gained additive
rolling-aggregate support keys (vol means, vol3/vol20, obv_diff_3, pct_change_3,
ad/obv 30d means, prev_close/volume, high, rsi_prev). **bullish/bearish/scalping
still the prior approximations** (next step). Scoring + API contract unchanged.
24 explicit-scenario tests in `test_categories.py`; backend 107 passed, Flutter
25 passed.
→ Remaining: migrate bullish/bearish/scalping faithfully (≥8/9 criteria forms).

**Phase 3 — RandomForest profit probability.** Port `label_profitable_signals`
+ `train_profit_model` into a `ml.py` module; expose an optional
`profit_probability` field on `AnalysisResult` (backward-compatible, like the
pagination metadata was). Cache models on disk per symbol. `scikit-learn` is
already a manageable dep.
→ Medium risk. Tests: deterministic with a fixed seed + synthetic labels.

**Phase 4 — Backtest endpoint.** Port `generate_historical_signals` +
`backtest_signals` behind a new `GET /v1/backtest/{symbol}` returning the stats
dict. Pure, deterministic, no new heavy deps.
→ Low risk. Tests: synthetic series with known forward returns.

**Phase 5 — Richer `/analyze`. ✅ DONE (2026-06-04, shipped as task "Phase 3").**
Migrated `analyze_screened_stocks` refinement logic into `engine.analyze`:
`buy_reasons[]` (OBV/CMF/A-D/VWAP/MACD/RSI confirmation), `support_resistance`
(rolling 10/50 min-max), ADX-banded `trailing_stop_percent`/`trailing_stop_price`
(tighter for scalping), a `recommendation` string, and a deterministic
`profit_probability` **placeholder** (score/100 — real RandomForest deferred to
the report's Phase 3/ML). All added as additive *optional* fields on
`AnalysisResult` (+ `immediate/major_support/resistance` keys in `compute_all`),
so the API contract is preserved and the mock fallback path simply omits them.
13 new tests; backend 121 passed, Flutter 25 passed. RL/LSTM/Telegram untouched.
→ Remaining for full ML: replace the profit-probability placeholder with the
RandomForest classifier (report Phase 3) and add the backtest endpoint (Phase 4).

**Deferred (separate research track, opt-in):** RL trader (PPO/TD3/SAC) and
LSTM predictor. Only if a concrete product need appears; they bring
`stable_baselines3`/`gymnasium`/`tensorflow` and non-determinism that fights
the current fast, hermetic test suite.

---

## 5. What can be REMOVED / left behind (do NOT migrate)

- **Telegram layer** — handlers, `ApplicationBuilder`, command parsing. The app
  is the new front end.
- **Flask `create_app` / `run_flask_app`** — superseded by FastAPI.
- **Subscription / billing / API-key / SQLite user tables** — out of scope for
  the analytics backend (handle separately if monetizing).
- **Rupiah string formatting & Telegram Markdown** — presentation; belongs in
  Flutter, not the API (API returns numbers).
- **`plot_trading_dashboard` / PNG visualizations** — the app renders charts.
- **`prepare_data` debug `print`s, augmented-close noise, event-flag** — noise /
  ML plumbing; reimplement clean.
- **TA-Lib dependency** — replace with pure pandas/numpy (already the backend's
  approach) to keep the build portable.
- **Per-call RL training inside `analyze_stock`** — pathologically slow and
  non-deterministic; do not port as-is.
- **Latent bugs not worth carrying:** scalping's `EMA_9/EMA_21` (never
  computed), duplicate `validate_api_key`/`add_user_to_db`/`start`
  definitions, mixed `all()`/`.any()` truthiness on Series.

---

## 6. Risks & cross-cutting notes

- **Market generality:** legacy is IDR/IDX-only (hard-coded `Rp` thresholds,
  `.JK`, price-<300 rules). Phase 2 must parameterize liquidity/price gates per
  market (IDX/HKEX/KOSPI/KOSDAQ) or they'll misfire on HKD/KRW tickers.
- **Contract stability:** every new field on `AnalysisResult`/`ScreenerResult`
  must be **additive/optional** (the Flutter models already parse unknown
  fields defensively — keep it that way).
- **Determinism:** prefer rule + RandomForest (seedable) over RL/LSTM to keep
  the hermetic, no-network test suite intact.
- **Indicator semantics:** legacy uses `iloc[-1]` vs `iloc[-2]` and rolling
  windows heavily; port carefully and unit-test each indicator against a known
  fixture before wiring into rules.

---

## 7. Suggested first commit boundary

Phase 1 (indicators) only: `indicators.py` gains `obv/ad/cmf/vwap/adx/sma/bbands`
+ `compute_all` keys, with unit tests — **no behavior change to `/screen` yet**.
That de-risks everything downstream and is reviewable in isolation.
