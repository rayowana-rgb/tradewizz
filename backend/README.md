# TradeWiz Backend

FastAPI backend for the TradeWiz mobile app. This is a skeleton that returns
deterministic **mock JSON matching the Flutter app's models** exactly, so the
app can talk to a real server before the screening engine (migrated from the
Telegram bot) is wired in.

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

## Layout

```
backend/
  app/
    main.py        # FastAPI app, routes, CORS, health
    models.py      # Pydantic models matching the Flutter contract
    mock_data.py   # Deterministic mock generators (mirror the app's mocks)
  tests/
    test_api.py    # Contract/shape tests
  requirements.txt
```

## Next steps

- Replace `mock_data.*` with the real screening/prediction engine.
- Add auth + rate limiting.
- Restrict CORS origins for production.
