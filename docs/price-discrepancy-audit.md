# Analyze Price-Discrepancy Audit & Fix

**Date:** 2026-06-05 ~17:10 WIB (18:04 GMT+8 task start)
**Scope:** Audit of the Analyze price pipeline + the confirmed fix.
No change to scoring, signals, categories, ranking, ML, or backtest.

## TL;DR

- **Root cause:** the OHLCV disk cache used a **fixed 6-hour TTL** for *all*
  candles. While the market is open (or shortly after), the **latest candle's
  Close keeps changing**, but TradeWizz served the **intraday snapshot captured
  at first fetch** for up to 6h → displayed price drifted from Yahoo's current
  Close.
- **Exact location:** `app/cache.py` `OhlcvCache._is_fresh` compared age against
  a constant `self._ttl` (= `DEFAULT_TTL_SECONDS = 6*60*60`, `app/cache.py:27`).
  The engine built the fetcher with that fixed TTL (`app/engine.py:247`).
- **Price source is correct:** Current Price = `compute_all(df)["close"]` =
  `df["Close"].iloc[-1]` (latest candle's raw Close). `_yf_fetch` uses
  `auto_adjust=False`; **Adj Close is not used** for price. Not a candle-
  selection or adjusted-price bug.
- **Fix:** market-aware (dynamic) cache TTL — short while any session is open
  (default 5 min) so the latest candle refreshes; long when all markets are
  closed (default 6h) since the final candle won't change.
- **Validated:** after the fix, TradeWizz Current Price == yfinance Close for
  BBCA/BBRI/SINI/BUVA.

## 1. Pipeline trace

```
GET /v1/analyze/{symbol}            app/main.py
  -> engine.analyze(symbol, market) app/engine.py
       -> df = self._fetch(...)     cached fetcher (make_cached_fetcher(_yf_fetch))
            -> OhlcvCache.get()      app/cache.py  (TTL freshness gate)
                 -> _yf_fetch()      app/engine.py:~139 (yf.download)
       -> ind = compute_all(df)      app/indicators.py:180
       -> highlights = _highlights(ind, market, last_date)
```

## 2. Which price is used (exact source)

- `app/indicators.py:195` `close = df["Close"]`; `app/indicators.py` returns
  `"close": last(close)` where `last()` = `series.dropna().iloc[-1]`
  (`indicators.py:189`). So **Current Price = the latest candle's `Close`**.
- `app/engine.py` `_highlights`: `Current Price: {price(ind.get('close'))}`.
- **Not** Adj Close / Open / High / Low. `_yf_fetch` sets `auto_adjust=False`,
  so `Close` is the raw close (and `Adj Close` is a separate, unused column).

## 3. Candle freshness (measured at ~17:10 WIB, market CLOSED, post-fix)

| Symbol | Latest Candle | Live Close | Adj Close | Current Price (engine) |
| ------ | ------------- | ---------- | --------- | ---------------------- |
| BBCA   | 2026-06-05    | 5,075      | 5,075     | 5,075                  |
| BBRI   | 2026-06-05    | 2,740      | 2,740     | 2,740                  |
| SINI   | 2026-06-05    | 9,400      | 9,400     | 9,400                  |
| BUVA   | 2026-06-05    | 610        | 610       | 610                    |

**Pre-fix evidence (cache age ~1.8h, captured intraday):**

| Symbol | cached_close (served) | live_close | drift |
| ------ | --------------------- | ---------- | ----- |
| BBCA   | 5,100 | 5,075 | −25 |
| BBRI   | 2,760 | 2,740 | −20 |
| SINI   | 9,400 | 9,400 | 0 |
| BUVA   | **344** | **610** | **+266** |

Same candle *date* in both — so the date-based market-status check still said
"today" — but the cached **Close value** was a stale intraday snapshot. This is
exactly the "cached previous/intraday data treated as live" failure mode.

## 4. Cache behavior

- TTL: `DEFAULT_TTL_SECONDS = 6h` (`app/cache.py:27`), env-overridable
  `TRADEWIZ_CACHE_TTL_SECONDS`.
- Hit path: `get()` -> `_try_read_fresh()` -> `_is_fresh()` (age < TTL) -> read
  CSV. Miss/expired: single-flight fetch + write.
- **Stale cause:** a 6h TTL means the first fetch during the trading session is
  frozen for 6h; subsequent Analyze calls reuse that intraday Close. Confirmed:
  cache file age 1.8h, served 5,100 while live was 5,075.

## 5. Yahoo download settings (`_yf_fetch`, app/engine.py)

```python
yf.download(ticker, period=..., interval=..., auto_adjust=False,
            progress=False, threads=False, timeout=_YF_TIMEOUT, session=<curl_cffi>)
```

- `auto_adjust=False` (raw OHLC; Adj Close present but unused for price)
- `repair` / `group_by` / `actions`: defaults (not set)
- `threads=False`
- **No `auto_adjust=True` and no use of `Adj Close` for Current Price.**

## 6. Candle selection

- Price uses `iloc[-1]` (latest). The only `iloc[-2]` usage is the `prev()`
  helper for MACD/RSI/OBV crossover deltas (`indicators.py:193`) — **not** the
  displayed price. No intentional "previous candle" for Current Price.

## 7. Market-open behavior

- yfinance daily candles: while the session is open, the latest daily candle is
  the *in-progress* one (its Close updates intraday). TradeWizz surfaces that
  latest candle's Close — correct — but the **cache froze it** for 6h. Post-fix,
  the short open-market TTL keeps it refreshed (within ~5 min).

## 8. Diagnostics

Added `app/diagnose_prices.py` (`python -m app.diagnose_prices`): logs per
symbol latest_data_date, live close, adj close, engine current price, cache_hit,
cached_close (flags drift), cached_candle_date, cache_file_age — for
BBCA/BBRI/SINI/BUVA.

## 9. Root cause (exact)

- **File/line:** `app/cache.py:27` (`DEFAULT_TTL_SECONDS = 6h`) applied in
  `OhlcvCache._is_fresh` (`app/cache.py:_is_fresh`), wired at
  `app/engine.py:247` (`make_cached_fetcher(_yf_fetch)` with the fixed TTL).
- **Cause:** a single 6h TTL for the most-recent (volatile) candle → stale
  intraday Close served as Current Price.

## 10. Fix (implemented)

- `OhlcvCache` now accepts `ttl_seconds` as an **int or a callable**, evaluated
  per freshness check (`_ttl_seconds()`), so the TTL can change with market
  state. (`app/cache.py`)
- Engine supplies a dynamic TTL (`_dynamic_cache_ttl`, `app/engine.py`):
  `_CACHE_TTL_OPEN = 300s` while any supported market is open,
  `_CACHE_TTL_CLOSED = 21600s` (6h) when all are closed. Env overrides:
  `TRADEWIZ_CACHE_TTL_OPEN`, `TRADEWIZ_CACHE_TTL_CLOSED`.
- No change to scoring/signals/categories/ranking/ML/backtest. Only the cache
  freshness window changed (plus diagnostics + tests).

## 11. Validation (post-fix)

After clearing the stale entries and refetching (market CLOSED at validation
time, so final candles):

| Symbol | yfinance Close | TradeWizz Current | Match |
| ------ | -------------- | ----------------- | ----- |
| BBCA   | 5,075 | 5,075 | OK |
| BBRI   | 2,740 | 2,740 | OK |
| SINI   | 9,400 | 9,400 | OK |
| BUVA   | 610   | 610   | OK |

Backend 174 tests pass; Flutter tests pass.

## Residual notes

- During open hours, Current Price can still lag the live tick by up to the
  open-market TTL (~5 min) — acceptable for a daily-candle screener, tunable via
  `TRADEWIZ_CACHE_TTL_OPEN`. The market-status/freshness highlights already tell
  the user whether data is live-session or previous-session.
- The historical 250-candle window is unaffected (older candles are final); the
  TTL change only governs how often the latest candle is refreshed.
