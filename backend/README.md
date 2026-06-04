# TradeWiz Backend

FastAPI backend for the TradeWiz mobile app. It runs a real analysis engine
(yfinance OHLCV + technical indicators) and **falls back to deterministic mock
JSON** if data fetch/computation fails — so the API never hard-fails and the
response shape always matches the Flutter app's models.

## Analysis engine

`app/engine.py` fetches daily OHLCV via **yfinance** and computes indicators in
pure pandas/numpy (`app/indicators.py`): **RSI(14), EMA20, EMA50, SMA200, MACD
(line/signal/hist), volume ratio, ATR / ATR%**. From these it derives a
BUY/HOLD/SELL signal, a 0–100 score, and the app's category taxonomy.

### Yahoo data source (HTTP 429 fix)

Yahoo's edge WAF blocks requests with the default `requests`/`urllib3` TLS
fingerprint (worst on macOS system Python built against **LibreSSL**) — returning
`HTTP/2 429 "Edge: Too Many Requests"` even when the IP is not over-quota and
browsers on the same network work. Root cause is **TLS/JA3 fingerprinting**, not
rate limiting, SSL errors, or the `requests`/yfinance version per se (plain
HTTPS to non-Yahoo hosts succeeds).

Fix: `_yf_fetch` passes yfinance a **`curl_cffi` session impersonating Chrome**
(`impersonate=chrome`), which presents a real-browser JA3 fingerprint and is
allowed through. Diagnostics:

```bash
python -m app.diagnose_yahoo        # checks env + raw vs impersonated requests
```

Override the browser profile with `TRADEWIZ_YF_IMPERSONATE` if it ages out. If
`curl_cffi` is unavailable the fetch degrades to yfinance's default session
(and may 429 again → mock fallback).

Market → yfinance suffix:

| Market | Suffix |
| ------ | ------ |
| IDX    | `.JK`  |
| HKEX   | `.HK`  |
| KOSPI  | `.KS`  |
| KOSDAQ | `.KQ`  |

Categories mapped from indicators: `bullish`, `bearish`, `scalping`,
`accumulation`, `pullback`, `accumulation_silent`, `turnaround_multibagger`,
`frequently_traded`, `short_candidate`, `ara_hunter`.

**Fallback:** any fetch error, empty data, or insufficient history routes to the
mock generators (`app/mock_data.py`).

For `/screen`, fallback is **per symbol**: if a single ticker fails to fetch, a
deterministic mock match (stable score/signal/categories from the symbol hash)
is substituted instead of dropping the symbol. So the endpoint returns `200`
quickly with the universe fully populated — which the Flutter app treats as live
backend data. (If the *entire* run yields nothing, it falls back to the generic
mock screen.)

### Symbol universes

`/screen/{market}` runs over a **per-market symbol universe** loaded from
`app/universe.py`. The primary source is the **Excel** export under
`data/universe/` (more complete); CSV is a fallback:

```
data/universe/idx.xlsx    hkex.xlsx    kospi.xlsx     (primary)
data/universe/idx.csv     hkex.csv     kospi.csv  kosdaq.csv  (fallback)
```

Approx sizes after normalization: IDX ~956, HKEX ~3822 (equities only), KOSPI
~948, KOSDAQ ~1822.

- **Resolution per market:** `<market>.xlsx` (primary) → for KOSDAQ, the
  combined `kospi.xlsx` → `<market>.csv` (fallback). Dir override:
  `TRADEWIZ_UNIVERSE_DIR`.
- Columns (case-insensitive): a symbol column named `symbol`/`ticker`/`code`,
  plus an optional `name` column. A single-column file works too.
- **Normalization on load** (the raw legacy Excel is not market-clean):
  - symbols are stripped of the yfinance suffix (`.JK/.HK/.KS/.KQ`) so the
    stored value is bare (re-appended idempotently at fetch time);
  - **HKEX**: only ordinary-equity board codes (1..9999) are kept (warrants/
    CBBCs/DRs dropped);
  - **KOSPI/KOSDAQ**: `kospi.xlsx` is a combined-Korea export, so rows are
    routed by source suffix — `.KS` → KOSPI, `.KQ` → KOSDAQ.
- Symbols are upper-cased, trimmed, and de-duplicated.
- Missing/invalid files yield an empty universe, and `/screen` then falls back
  to mock output. Symbols that fail to fetch get per-symbol mock data.

Edit these files to control exactly which tickers get screened.

### OHLCV cache

`app/cache.py` memoizes yfinance fetches on disk, keyed by resolved Yahoo
ticker + period + interval, to avoid repeat calls and Yahoo rate limits. Entries
expire after a TTL (default **6 hours**). The inner fetcher stays injectable, so
tests run with no network.

Config via environment:

| Variable                       | Default                | Purpose                  |
| ------------------------------ | ---------------------- | ------------------------ |
| `TRADEWIZ_CACHE_DIR`           | `backend/.cache/ohlcv` | Where cache files live   |
| `TRADEWIZ_CACHE_TTL_SECONDS`   | `21600` (6h)           | Cache entry time-to-live |

The cache dir is git-ignored. Corrupt/unreadable entries are transparently
refetched; fetch errors propagate (and are not cached) so the engine's mock
fallback still applies.

**Single-flight concurrency guard:** simultaneous cold requests for the same
ticker+period+interval share one underlying fetch. The first caller acquires a
per-key `threading.Lock` and fetches; others block, then read the freshly
written cache instead of issuing duplicate yfinance calls. Real thread locks are
used (FastAPI runs sync endpoints in a threadpool). Failed fetches are not
cached, so they never poison subsequent reads.

## Endpoints

All under the `/v1` prefix.

| Method | Path                          | Returns            |
| ------ | ----------------------------- | ------------------ |
| GET    | `/v1/health`                  | health status      |
| GET    | `/v1/analyze/{symbol}`        | `AnalysisResult`   |
| GET    | `/v1/screen/{market}`         | `ScreenerResult`   |
| GET    | `/v1/predict_weekly/{symbol}` | `WeeklyPrediction` |
| GET    | `/v1/backtest/{symbol}`       | `BacktestResult`   |

- `analyze` accepts an optional `?market=IDX|HKEX|KOSPI|KOSDAQ` query param.
- `screen` returns 404 for unknown markets, and supports:
  - `?limit=` top-N matches, `1..200` (default `50`).
  - `?min_score=` minimum score, `0..100` (default `0`).
  - `?categories=` comma-separated category filter (e.g. `bullish,scalping`);
    a match must carry at least one. Unknown names are ignored.
  - Results are sorted by **score desc, then change_percent desc**.
  - Example: `/v1/screen/IDX?limit=20&min_score=70&categories=bullish,ara_hunter`
  - The response includes pagination metadata: `total_count` (matches after
    filtering, before the limit), `returned_count`, `limit`, `min_score`, and
    `categories` — enabling “showing N of M” + load-more in clients.
- `backtest` accepts `?market=`, `?signal_type=momentum|scalping|accumulation`
  (default momentum), and `?forward_days=` (1..30, default 2). Returns
  `win_rate`, `average_return`, `profit_factor`, `max_drawdown`, and
  `total_signals`/`total_wins`/`total_losses`. Bad `signal_type` → 400; no data
  → a zeroed 200. `profit_factor` is capped finite (999) when there are no
  losing trades (JSON has no Infinity).
- Interactive docs: `http://localhost:8000/docs`.

## Setup

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

`--host 0.0.0.0` makes it reachable from a phone/simulator on your LAN.

### Point the Flutter app at it

```bash
# iOS simulator / same machine
flutter run --dart-define=TRADEWIZ_API_BASE_URL=http://localhost:8000/v1

# Physical device on the same network (replace with your machine's LAN IP)
flutter run --dart-define=TRADEWIZ_API_BASE_URL=http://192.168.1.100:8000/v1
```

CORS is permissive (`allow_origins=["*"]`) for development. Tighten it before
deploying to production.

## Test

```bash
source .venv/bin/activate
python -m pytest -q
```

## End-to-end smoke test

From the repo root, one command starts this backend, runs the Flutter live
smoke test against it (asserting the app gets **live** data), and tears down:

```bash
./scripts/e2e_smoke.sh
```

## Layout

```
backend/
  app/
    main.py        # FastAPI app, routes, CORS, health
    models.py      # Pydantic models matching the Flutter contract
    indicators.py  # Pure pandas/numpy indicators (RSI/EMA/SMA/MACD/ATR/...)
    cache.py       # On-disk OHLCV cache (ticker+period+interval, TTL)
    universe.py    # Per-market symbol universes (Excel-primary loader + normalize)
    engine.py      # yfinance fetch (cached) + categorize + signal/score
    mock_data.py   # Deterministic mock generators (mirror the app's mocks)
  data/
    universe/      # idx/hkex/kospi.xlsx (primary) + *.csv fallback
  tests/
    test_api.py        # Contract/shape tests (forced mock fallback, no network)
    test_indicators.py # Indicator math (synthetic data)
    test_engine.py     # Engine logic + fallback (injected fetchers, no network)
    test_cache.py      # Cache hit/miss/expiry (fake clock, no network)
    test_cache_concurrency.py # Single-flight guard (real threads, no network)
    test_universe.py   # Universe loader: CSV/Excel, dedupe, fallbacks
  requirements.txt
```

## Next steps

- Replace `mock_data.*` with the real screening/prediction engine.
- Add auth + rate limiting.
- Restrict CORS origins for production.
