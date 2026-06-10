# TradeWizz — Project Memory

Durable context for future agents. Read this **before modifying scoring or
screener logic.** Append, don't rewrite history.

---

## Legacy bot9.py Knowledge

> Full deep-dive: [`docs/bot9_memory.md`](./bot9_memory.md). Source file:
> `legacy_bot/bot9.py` (2,839 lines). Compact memory below.

**What it is.** `bot9.py` was the **original IDX (Jakarta) stock-analysis
Telegram bot** that predates the TradeWizz backend + Flutter app. It is a
monolith: a Telegram bot + a small Flask keepalive + SQLite subscription
gating. It fetches OHLCV via `yfinance`, builds a large `pandas_ta`/`talib`
indicator stack, screens the whole IDX universe into ~11 strategy buckets, and
analyzes single names with RL (Stable-Baselines3 PPO/TD3/SAC), a RandomForest
profit classifier, an LSTM 3-day forecaster, and a forward-return backtest.

**Commands.** `/start /subscribe /activate /cancel_subscription /status`
`/set_balance` `/analyze` (RL Buy/Sell/Hold or a saved category) `/analyze_all`
`/screen` (whole-IDX screener) `/financial` (fundamentals)
`/analyze_screened_stocks` (deep analysis + final liquidity gate). No
`/predict_weekly` or `/volume_profile` exist — weekly prediction = LSTM forecast
inside `/analyze_screened_stocks`.

**Indicators.** SMA 20/50/200, EMA5, RSI14, MACD(12/26/9)+hist, OBV, A/D
(`Accum_Dist`), VWAP, CMF20, Momentum10, Williams%R, ATR14, ADX14, Bollinger(20,2),
candlesticks (Doji/Hammer/Engulfing/ShootingStar/Harami). Support/Resistance =
10-day (immediate) and 50-day (major) rolling extremes. Trend = SMA50 vs SMA200.

**Screener buckets + their liquidity floors** (value traded = `Close × Volume`,
Rupiah): bullish/bearish/scalping/pullback need the **Rp2B general gate**;
accumulation **≥Rp10B**; frequently_traded **>Rp10B**; ARA hunter **≥Rp5B**;
turnaround multibagger **≥Rp500M** (price<250); backdoor **>Rp500M** (price<300);
silent accumulation (price<100). Buckets use **N-of-M consensus** (bullish ≥8/11,
bearish ≥7/9, scalping ≥9) and require **money-flow confirmation** (rising OBV +
A/D, positive CMF). No single indicator can trigger a signal.

### Liquidity requirements (the rules that prevent the current regression)
bot9 treated **liquidity as a hard gate, never a weight.** A name failing
value-traded thresholds is excluded outright regardless of how strong its
technicals are. The **final output gate** in `analyze_screened_stocks`:

```
should_output = is_buy_reco or lstm_uptrend          # real BUY (no SELL/HOLD/AVOID) or LSTM uptrend
emit only if:  should_output
           AND (today_volume >= 20,000,000 shares OR value_traded >= Rp1B)
           AND avg_value_traded_30d >= Rp3B           # sustained liquidity, MANDATORY
```

So a stock with `value_traded ≈ 0` can **never** be recommended. The key idea
the current app should keep adopting is the **30-day average value traded ≥ Rp3B**
sustained-liquidity test, not just a spot check.

**ML / profit logic.** RL agent (continuous action ∈[-1,1] → Buy/Sell/Hold,
confidence = |action|×100, position sizing, Sharpe) drives `/analyze`.
RandomForestClassifier → **profit probability** = P(forward 3-day return > 1%).
LSTM(2×64) → **3-day predicted price** + trend (MAPE/MSE reported). Rule-based
2-day forward **backtest** → win rate / avg return. Dynamic **ATR/ADX trailing
stop** (scalping 2–5%, swing/momentum 5–10%) on every recommendation.

**Output style.** Telegram Markdown/HTML cards: price, RSI, MACD(+signal+hist),
VWAP, SMA50/200, ADX, ATR, Volume, **Value Traded (Rp)**, **Avg Volume/Value
(30d) + ratios**, Recommendation, Reasons list, Trailing Stop, LSTM forecast,
backtest summary, profit probability. Reasons are human phrases ("MACD Bullish",
"OBV Naik", "Volume Spike", "Di Atas VWAP"). Only high-conviction BUYs are shown.

### Old scoring philosophy (preserve this)
*"Confirmed momentum + smart-money flow, only in genuinely liquid names,
surfaced only when it's a real BUY."* Specifically:
1. **Liquidity is a hard prerequisite applied last; technicals never override it.**
2. **Money-flow (OBV + A/D + CMF) confirmation is mandatory** for a BUY.
3. **Consensus (N-of-M), not single-indicator.**
4. **Higher-risk plays require higher liquidity** (ARA Rp5B, freq Rp10B), not lower.
5. **Cheap micro-caps (price<100–300) with tiny rupiah volume are traps** — the
   exact illiquid names the gates exist to block.

### Relationship to the current liquidity regression
The current app had a regression where **illiquid `value_traded = 0` stocks could
score 90+ / BUY**. bot9 never had this bug because liquidity was a gate, not a
feature. The shipped fix (per-market liquidity-cap tiers applied *after* the final
score, radar exclusion, Flutter `isIlliquid` filter, snapshot v2 invalidation) is
the same medicine generalized per market. bot9's thresholds **validate** that fix
and suggest the next step: add **sustained 30-day average value traded** as a
second, mandatory liquidity signal. **Do not reintroduce any path where technical
strength can lift an illiquid stock's score above the liquidity cap.**
