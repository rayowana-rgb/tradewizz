#!/usr/bin/env bash
#
# End-to-end smoke test for TradeWiz.
#
# Starts the FastAPI backend, runs the Flutter live smoke test against it
# (verifying the app receives LIVE data, not mock fallback), then shuts the
# backend down. Exits non-zero if any step fails.
#
# Usage:
#   ./scripts/e2e_smoke.sh [PORT]   # default port 8000
set -euo pipefail
set -m  # job control: background job becomes its own process-group leader

PORT="${1:-8000}"
BASE_URL="http://localhost:${PORT}/v1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="${ROOT}/backend"
APP="${ROOT}/tradewiz"
LOG="$(mktemp -t tradewiz_backend.XXXXXX.log)"

echo "==> Project root: ${ROOT}"

if [[ ! -d "${BACKEND}/.venv" ]]; then
  echo "ERROR: ${BACKEND}/.venv not found. Create it first:" >&2
  echo "  cd backend && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${BACKEND}/.venv/bin/activate"

echo "==> Starting backend on port ${PORT} (log: ${LOG})"
# Run in its own process group so cleanup can reap uvicorn + any children.
( cd "${BACKEND}" && exec uvicorn app.main:app --host 0.0.0.0 --port "${PORT}" >"${LOG}" 2>&1 ) &
BACKEND_PID=$!

cleanup() {
  echo "==> Stopping backend (pid ${BACKEND_PID})"
  # Kill the process group, then belt-and-braces match by command line.
  kill -- "-${BACKEND_PID}" 2>/dev/null || kill "${BACKEND_PID}" 2>/dev/null || true
  pkill -f "uvicorn app.main:app --host 0.0.0.0 --port ${PORT}" 2>/dev/null || true
  wait "${BACKEND_PID}" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Waiting for /v1/health ..."
for i in $(seq 1 30); do
  if curl -fsS "${BASE_URL}/health" >/dev/null 2>&1; then
    echo "==> Backend healthy."
    break
  fi
  if ! kill -0 "${BACKEND_PID}" 2>/dev/null; then
    echo "ERROR: backend exited early. Log:" >&2
    cat "${LOG}" >&2
    exit 1
  fi
  sleep 0.5
  if [[ "${i}" == "30" ]]; then
    echo "ERROR: backend did not become healthy in time. Log:" >&2
    cat "${LOG}" >&2
    exit 1
  fi
done

echo "==> Running Flutter live smoke test against ${BASE_URL}"
cd "${APP}"
flutter test --tags live \
  --dart-define=TRADEWIZ_API_BASE_URL="${BASE_URL}" \
  --dart-define=RUN_LIVE=true

echo "==> E2E smoke PASSED: app received LIVE backend data."
