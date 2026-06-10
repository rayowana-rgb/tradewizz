# bot9.py — Legacy Telegram Stock Bot: Preserved Knowledge

> Research/documentation only. Source: `legacy_bot/bot9.py` (2,839 lines).
> This is the **original IDX stock analysis Telegram bot** that predates the
> TradeWizz backend + Flutter app. It encodes years of hand-tuned IDX trading
> rules — especially **liquidity / value-traded gates** — that must not be lost.
> Nothing here has been ported yet.

---

## 1. Executive Summary

`bot9.py` is a monolithic Python service that runs **two things at once**:

- A **Telegram bot** (`python-telegram-bot`) exposing analysis + screening
  commands for Indonesian (IDX/Jakarta) stocks.
- A small **Flask app** (health/keepalive on `$PORT`, default 8080) plus a
  SQLite users table for subscription/API-key gating.

It fetches OHLCV via `yfinance`, computes a large technical-indicator stack
(`pandas_ta` + `talib`), screens the whole IDX universe into ~11 strategy
buckets, and analyzes individual names with a stack of models:

- **Reinforcement Learning** (Stable-Baselines3 PPO/TD3/SAC + RecurrentPPO over
  a custom `gym` trading env) → the `/analyze` Buy/Sell/Hold action + confidence.
- **RandomForestClassifier** → **profit probability** (P(forward return > 1%)).
- **LSTM** (Keras) → **3-day price forecast** (predicted price / trend).
- A **rule-based forward-return backtest** → win rate / avg return per signal.

**The single most important thing in this file is its liquidity discipline.**
Every screener bucket and the final output stage are gated on **value traded**
(price × volume, in Rupiah) and average value traded. Illiquid names are
*structurally impossible* to surface. This is exactly the property the current
TradeWizz scoring regression lost (illiquid `value_traded = 0` could score 90+).

---

## 2. Commands Summary

Registered in `async_main()`:

| Command | Handler | Purpose |
|---|---|---|
| `/start` | `start` | Onboarding / register user |
| `/subscribe` | `subscribe` | Begin subscription flow |
| `/activate <key>` | `activate_subscription` | Activate API key, set expiry |
| `/cancel_subscription` | `cancel_subscription` | Deactivate key |
| `/status` | `check_api_key` | Show key status/expiry |
| `/set_balance <Rp>` | `set_balance` | Set simulated balance (default Rp10,000,000) |
| `/analyze <SYMS|category>` | `analyze` | RL-driven Buy/Sell/Hold per symbol, or analyze a saved screener category (`bullish`/`accum`/`pullback`) |
| `/analyze_all` | `analyze_all` | Analyze a predefined list, resumable by start index |
| `/screen` | `screen_idx_stocks` | **Screen the whole IDX universe** into all buckets |
| `/financial` | `screen_financial_stocks` | Fundamental screen (PER/PBV/ROE/DER etc.) |
| `/analyze_screened_stocks` | `analyze_screened_stocks` | **Deep analysis** of saved screener buckets: signals, trailing stop, profit prob, LSTM, backtest, **final liquidity gate** |

Note: there is **no** `/predict_weekly` or `/volume_profile` command in this
file; weekly prediction is delivered via the LSTM 3-day forecast embedded in
`/analyze_screened_stocks`, and "volume profile" exists only as indicators
(OBV, A/D, VWAP, value/volume ratios), not a standalone command.

Gating: most commands call `validate_api_key(user_id)` first and refuse without
an active subscription.

---

## 3. Indicator List (`prepare_data`)

Computed on every prepared OHLCV frame (daily by default):

- **Moving averages:** SMA_20, SMA_50, SMA_200, EMA_5, plus MA50/MA200 for phase.
- **Momentum/oscillators:** RSI(14), Momentum(10), Williams %R(14), MACD(12/26/9)
  with signal + histogram, CMF(20), ADX(14).
- **Volume/flow:** OBV, Accumulation/Distribution (`ta.ad` → `Accum_Dist`),
  VWAP, Volume_Avg(20), rolling volume means (3/5/10/20/30).
- **Volatility/bands:** ATR(14), Bollinger Bands (20, 2σ) upper/middle/lower.
- **Support/Resistance (rolling extremes):**
  - Immediate Support/Resistance = 10-day Low.min() / High.max()
  - Major Support/Resistance = 50-day Low.min() / High.max()
- **Candlesticks (talib):** Doji, Hammer, Engulfing, Shooting Star, Harami,
  Harami Cross.
- **Market phase:** `Market_Phase = +1` if MA50>MA200 (bullish), `-1` if
  MA50<MA200 (bearish), else 0. `detect_market_trend()` uses SMA_50 vs SMA_200.
- **Event flag:** rows with |daily % change| > 2% flagged as events.

---

## 4. Screener Category Rules

Driver: `screen_momentum_stocks(symbols)` loops the IDX universe, calls
`prepare_data`, computes `nominal_value = Close × Volume`, applies the
**general Rp2B liquidity gate**, then tests each bucket. Results are persisted
via `store_screened_stocks` / `get_screened_stocks`.

| Bucket | Core rule (summarized) | Liquidity gate |
|---|---|---|
| **bullish** (`screen_bullish`) | ≥8 of 11: Close>SMA50, SMA50>SMA200·1.01 (golden cross), RSI rising & >55, MACD>Signal, MACD>-0.2, near BB upper (97%), strong candle, vol surge >1.2×, OBV rising, A/D rising, ADX>18/25 | Rp2B general |
| **bearish** (`screen_bearish`) | ≥7 of 9 **reversal** signals: RSI<40 but rising (divergence), MACD bullish/weak, Close>SMA20, vol+OBV+A/D confirmation, near 50-day support, SMA50 rising | Rp2B general |
| **scalping** (`screen_scalping_stocks`) | ≥9 conditions: RSI 50–75, Close>VWAP, ATR>1.15×avg, vol>1.5×, OBV/A-D up, above short EMAs, MACD bullish, BB breakout — AND **no exit signal** (RSI>80 or upper-band rejection) | Rp2B general |
| **pullback** (`screen_pullback`) | ALL: uptrend (SMA50>SMA200), Close>SMA200, Close<SMA20 (dip), RSI 40–60 cooling, MACD>0 but <Signal, volume decreasing | Rp2B general |
| **accumulation** (`screen_accumulation`) | strong A/D > 30d mean·1.1, OBV>30d mean, vol>30d mean·1.2, price not exploded (Close<SMA50·1.15) | **value traded ≥ Rp10B** |
| **backdoor_candidate** | vol spike >2.5×20d, price stagnant (|5d chg|<3%), OBV up, **cheap price <300** | **nominal ≥ Rp500M** |
| **turnaround** (multibagger) | value≥Rp500M, **price<250**, Close>MA20>MA50, vol_3/vol_20>1, CMF>0, OBV up, RSI 30–60 | **value ≥ Rp500M** |
| **ara_hunter** (limit-up play) | Close≥prev·1.06 (near ARA), Close≥High·0.98, vol>3×10d, RSI>70, MACD>Signal, A/D & OBV up, Close>SMA20 | **nominal ≥ Rp5B** |
| **short_candidate** | RSI>70 turning down, MACD<Signal, MACD hist<0, Close<SMA20, vol>1.5×10d, OBV down, A/D down | (bearish, vol-confirmed) |
| **frequently_traded** | vol>2×20d-avg AND **nominal > Rp10B** | **nominal > Rp10B** |
| **swing_trade** | MA20>MA50 (or MA50>MA200), MA20 rising, near MA20 (±5%), RSI 42–72, ADX 18–35, vol dry-up OR expand, MACD green-flip OR strong curl-to-zero | nominal ≥ small floor + price≥50 |
| **silent_accumulation** (`screen_silent_accumulation_candidates`) | **price <100**, vol_3/vol_20>2, |3d chg|<2%, CMF>0, OBV up | small-cap focus (Rp500M tier elsewhere) |
| **sleeping_giants** / **insider_activity** | helpers: long consolidation + vol spike + early momentum / OBV+A/D+volume+breakout | (defined, used opportunistically) |

`screen_financial_stocks` (fundamentals via `fetch_financial_data` +
`analyze_fundamentals`) screens on PER/PBV/ROE/DER-type ratios — separate track.

---

## 5. Liquidity Thresholds (THE CRITICAL PART)

All values are **Rupiah of value traded = Close × Volume** unless noted. These
are the rules that kept illiquid garbage out of every result.

### Screener-level gates (`screen_momentum_stocks`)
- `MIN_VALUE_IDR = 2,000,000,000` → **Rp2B general gate**. If a stock's daily
  `Close × Volume < Rp2B`, it is **skipped for all general strategies**
  (bullish/bearish/scalping/pullback/accumulation). `skip_general = True`.
- `MIN_SILENT_ACCUM_IDR = 500,000,000` → Rp500M floor for silent-accumulation /
  small-cap special cases.
- **ara_hunter:** `nominal_value >= 5,000,000,000` (Rp5B).
- **frequently_traded:** `nominal_value > 10,000,000,000` (Rp10B) + volume>2×20d.
- **backdoor_candidate:** `nominal_value > 500,000,000` (Rp500M).
- **turnaround:** `value_traded >= 500,000,000` (Rp500M).
- **accumulation:** `value_traded >= 10,000,000,000` (Rp10B) — high bar.
- **swing_trade:** `nominal_value >= MIN_VALUE_IDR (small floor)` AND `Close ≥ 50`.

### Final OUTPUT gate (`analyze_screened_stocks`) — most important
A stock is only ever printed to the user if **ALL** of these hold:

```python
min_nominal_volume = 1_000_000_000        # Rp1B
should_output = is_buy_reco or lstm_uptrend
if (should_output
    and (latest["Volume"] >= 20_000_000 or nominal_volume >= min_nominal_volume)
    and avg_value >= 3_000_000_000):       # 30-day AVG value traded ≥ Rp3B
    # ... only now build and send the analysis card
```

Decoded:
1. **Signal gate:** must be a real BUY (or LSTM uptrend) — never SELL/HOLD/AVOID
   (regex-cleaned recommendation must contain "BUY" and none of SELL/HOLD/AVOID).
2. **Today's liquidity:** volume ≥ **20,000,000 shares** OR value traded ≥ **Rp1B**.
3. **Sustained liquidity (mandatory):** **30-day average value traded ≥ Rp3B**.

The 30-day average requirement is key: it rejects names that had a single
freak-volume day but are normally dead. A `value_traded = 0` (or near-zero)
stock **cannot pass** any of these gates → it can never be recommended.

### Other liquidity-aware metrics shown
- `avg_volume` / `avg_value` over 30 days, and `volume_ratio` / `value_ratio`
  (today vs 30d avg) are displayed so users see how unusual today's activity is.

---

## 6. ML Components

| Component | Library | Role | Output |
|---|---|---|---|
| **RL agent** | Stable-Baselines3 **PPO/TD3/SAC**, `sb3_contrib.RecurrentPPO`, custom `LSTMStockTradingEnv`/`MomentumTradingEnv` (gymnasium) | `/analyze` decision engine | Continuous action ∈ [-1,1] → Buy(>0)/Sell(<0)/Hold(0); `confidence = |action|×100`; position sizing vs balance; reports net profit, precision, Sharpe |
| **Profit classifier** | `RandomForestClassifier(n_estimators=100)` | `train_profit_model` labels `Profitable = (forward 3-day return > 1%)`; features: RSI, MACD(+signal+hist), VWAP, SMA20/50/200, OBV, A/D, ADX, ATR, Volume | **Profit Probability %** = `predict_proba()[1]` |
| **LSTM forecaster** | Keras Sequential (2× LSTM(64)+Dropout) | `train_lstm_model` (120d, 60-step seq → predict next 3 closes), `predict_next_days` | 3-day **predicted price** + Up/Down trend; reports MAPE/MSE |
| **Rule backtest** | pure pandas | `generate_historical_signals` (momentum/scalping/accumulation) + `backtest_signals` (2-day forward) | n_signals, **avg return %**, **win rate %**, max/min |
| **Sharpe** | `calculate_sharpe_ratio` | risk-adjusted RL eval | Sharpe ratio |

Models are cached per symbol on disk (`rf_models/`, `lstm_models/`,
VecNormalize files) and retrained on feature mismatch.

---

## 7. Scoring Philosophy

bot9.py does **not** emit a single 0–100 score. Instead it uses
**multi-gate confirmation**:

1. **Trend context first** (`detect_market_trend`: SMA50 vs SMA200) selects which
   bucket logic even applies.
2. **Consensus of many indicators** — buckets require *N of M* conditions
   (e.g. bullish ≥8/11, bearish ≥7/9, scalping ≥9) across price, momentum,
   volume **and money-flow** (OBV + A/D + CMF). No single indicator can trigger.
3. **Volume/flow confirmation is mandatory** — almost every BUY requires a volume
   spike + rising OBV + rising A/D ("smart money"). Price action alone is never
   enough.
4. **Liquidity is a hard prerequisite, applied last** — even a perfect technical
   setup is discarded if it fails the value-traded gates (§5). Liquidity is a
   gate, not a weighted feature, and **technicals can never override it**.
5. **Output only actionable BUYs** — the final gate suppresses HOLD/SELL noise
   and only surfaces high-conviction, liquid, BUY-or-LSTM-uptrend names.
6. **Risk management baked in** — dynamic ATR/ADX trailing stop (scalping 2–5%,
   swing/momentum 5–10%) attached to every recommendation.

Philosophy in one line: **"Confirmed momentum + smart-money flow, only in
genuinely liquid names, surfaced only when it's a real BUY."**

---

## 8. Important Differences vs Current TradeWizz App

### What bot9.py does better
- **Hard liquidity gates everywhere** (Rp2B general, Rp3B 30-day avg output gate,
  per-bucket Rp500M–Rp10B). Illiquid names are structurally impossible to show.
- **Mandatory money-flow confirmation** (OBV + A/D + CMF) on nearly every signal.
- **30-day average value traded** as a sustained-liquidity check (not just today).
- **Output gate that only emits real BUYs** (regex-cleaned, no HOLD/SELL leakage).
- Rich **IDX-specific strategies**: ARA hunter (limit-up), backdoor/akuisisi,
  turnaround multibagger (price<250), silent accumulation (price<100).
- **Profit probability + 2-day backtest win rate** shown alongside each idea.
- **Dynamic ATR/ADX trailing stop** tiers.

### What the current TradeWizz app does better
- **Per-market** support (US/IDX/JP/IN/VN/SG/HK/KR), not IDX-only.
- A **single calibrated 0–100 score + signal band** that's easy to rank/compare.
- **Snapshot/CDN offline-first** delivery, Flutter UI, watchlist, portfolio sim,
  brokers, journal, onboarding, notifications.
- A clean **backend service architecture** + test suites (765 backend tests).
- The recent **liquidity-cap fix** (per-market tiers, applied after final score)
  — which is conceptually the same medicine bot9 always had, now generalized.
- Rule-based **Fear/Greed market condition**, market index cards.

### The regression bot9.py can fix
The current app's regression: **illiquid stocks with `value_traded = 0` could
score 90+ / BUY.** bot9.py never had this bug because liquidity was a *hard gate*,
not a feature weight. The fix already shipped (per-market caps + radar exclusion +
`isIlliquid` filter); bot9's thresholds **validate and can tighten** those caps,
especially the **30-day average value-traded** idea, which the app should adopt.

---

## 9. Recommended Migration Plan (NOT implemented yet)

Priority order, additive, no rewrite:

1. **(Done/verify) Hard liquidity gate** — confirm backend `apply_liquidity_cap`
   matches bot9 intent: `value_traded` missing/0/tiny ⇒ capped ≤50, never BUY.
2. **Adopt 30-day average value traded** as a second liquidity signal
   (`avg_value_traded`) and gate on it, mirroring bot9's `avg_value ≥ Rp3B`.
   The app already prefers `avg_value_traded` in `_value_traded()`; ensure the
   data pipeline populates it and that the cap considers sustained, not just spot.
3. **Money-flow confirmation** — add OBV + A/D (+ CMF) "smart-money rising" as a
   scoring input / BUY prerequisite, so price-only spikes don't score high.
4. **Port IDX strategy buckets** as opportunity tags (ARA hunter, turnaround<250,
   backdoor, silent accumulation) into the radar/screener, each with its own
   value-traded floor from §5.
5. **Profit probability** — port the RandomForest forward-return classifier as an
   optional confidence overlay (P(return>1% in 3d)).
6. **2-day/3-day forward backtest win rate** per signal as a trust metric.
7. **Dynamic ATR/ADX trailing stop** tiers in the analysis detail.
8. **LSTM 3-day forecast** — optional predicted-price module (heavier; later).
   RL `/analyze` engine is likely too heavy/non-deterministic to port directly;
   keep the current deterministic scoring as the primary engine.

Migrate liquidity + money-flow rules **first**; ML overlays later.

---

## 10. Critical Rules That Must NOT Be Lost

1. **Liquidity is a HARD GATE, never a weight.** A name failing value-traded
   thresholds is excluded outright, no matter how good the technicals look. This
   is exactly the property the regression broke — preserve it forever.
2. **`value_traded = Close × Volume` (Rupiah).** Spot value gate ~Rp1–2B;
   **sustained 30-day average value ≥ Rp3B** is the real investability test.
3. **Per-strategy liquidity floors:** general Rp2B; turnaround/backdoor Rp500M;
   ARA Rp5B; frequently_traded/accumulation Rp10B. Higher-risk plays need higher
   liquidity, not lower.
4. **Money-flow confirmation (OBV + A/D + CMF) is mandatory** for a BUY. Price
   action alone never qualifies.
5. **Consensus, not single-signal.** Buckets need N-of-M conditions. One hot
   indicator must not produce a high score.
6. **Only surface real BUYs.** Don't flood users with HOLD/SELL; gate output on a
   clean BUY (or model-confirmed uptrend) AND liquidity.
7. **Risk first:** every recommendation carries a trailing stop sized by ATR/ADX.
8. **IDX micro-cap traps:** very cheap stocks (price<100–300) can show huge %
   moves on tiny rupiah volume — these are the illiquid traps the gates exist to
   block. Cheap price + low value traded = exclude.
