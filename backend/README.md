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
mock generators (`app/mock_data.py`). `/screen/{market}` returns mock output
until a symbol universe is configured.

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

## Endpoints

All under the `/v1` prefix.

| Method | Path                          | Returns            |
| ------ | ----------------------------- | ------------------ |
| GET    | `/v1/health`                  | health status      |
| GET    | `/v1/analyze/{symbol}`        | `AnalysisResult`   |
| GET    | `/v1/screen/{market}`         | `ScreenerResult`   |
| GET    | `/v1/predict_weekly/{symbol}` | `WeeklyPrediction` |

- `analyze` accepts an optional `?market=IDX|HKEX|KOSPI|KOSDAQ` query param.
- `screen` returns 404 for unknown markets.
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
    engine.py      # yfinance fetch (cached) + categorize + signal/score
    mock_data.py   # Deterministic mock generators (mirror the app's mocks)
  tests/
    test_api.py        # Contract/shape tests (forced mock fallback, no network)
    test_indicators.py # Indicator math (synthetic data)
    test_engine.py     # Engine logic + fallback (injected fetchers, no network)
    test_cache.py      # Cache hit/miss/expiry (fake clock, no network)
  requirements.txt
```

## Next steps

- Replace `mock_data.*` with the real screening/prediction engine.
- Add auth + rate limiting.
- Restrict CORS origins for production.
