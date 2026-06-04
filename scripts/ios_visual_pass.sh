#!/usr/bin/env bash
#
# Launch TradeWiz on the iOS Simulator against the local backend, for a manual
# visual pass (Dashboard / Screener / Analysis / Watchlist -> green "Live").
#
# Prereqs (see docs/ios-simulator-setup.md): full Xcode selected, an iOS
# simulator runtime installed, and CocoaPods. This script checks them and
# prints the fix commands if something is missing.
#
# Targets the iPhone 16 Plus simulator by default, resolved dynamically to its
# UDID (override with SIM_NAME="iPhone 16 Pro"); falls back to any available
# iPhone if the preferred one isn't installed.
#
# Usage: ./scripts/ios_visual_pass.sh [PORT]   (default 8000)
set -euo pipefail
set -m

PORT="${1:-8000}"
BASE_URL="http://127.0.0.1:${PORT}/v1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="${ROOT}/backend"
APP="${ROOT}/tradewiz"
LOG="$(mktemp -t tradewiz_ios_backend.XXXXXX.log)"

fail() { echo "ERROR: $*" >&2; exit 1; }

echo "==> Checking iOS toolchain..."
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "${DEV_DIR}" != *Xcode.app* ]]; then
  cat >&2 <<'EOF'
Xcode is not the active developer dir. Fix:
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -runFirstLaunch
  sudo xcodebuild -license accept
See docs/ios-simulator-setup.md.
EOF
  exit 1
fi

command -v pod >/dev/null 2>&1 || fail \
  "CocoaPods not installed. Run: brew install cocoapods (see docs/ios-simulator-setup.md)"

if ! xcrun simctl list runtimes 2>/dev/null | grep -qi "iOS"; then
  fail "No iOS simulator runtime. Run: xcodebuild -downloadPlatform iOS"
fi

echo "==> Toolchain looks OK."

# --- Pick a simulator dynamically ------------------------------------------
# Prefer iPhone 16 Plus; override with SIM_NAME="iPhone 16 Pro" etc. Falls back
# to any available iPhone if the preferred one isn't installed.
PREFERRED_SIM="${SIM_NAME:-iPhone 16 Plus}"

# Find "<UDID> (Booted|Shutdown)" for a device name among available devices.
sim_udid_for() {
  local name="$1"
  xcrun simctl list devices available 2>/dev/null \
    | grep -F "${name} (" \
    | head -n1 \
    | grep -oE '[0-9A-Fa-f-]{36}' \
    | head -n1
}

SIM_UDID="$(sim_udid_for "${PREFERRED_SIM}")"
if [[ -z "${SIM_UDID}" ]]; then
  echo "==> '${PREFERRED_SIM}' not found; picking the first available iPhone..."
  FIRST_IPHONE="$(xcrun simctl list devices available 2>/dev/null \
    | grep -oE 'iPhone [^(]*\(' | sed 's/ ($//' | head -n1 | sed 's/[[:space:]]*$//')"
  [[ -n "${FIRST_IPHONE}" ]] || fail "No available iPhone simulators. Run: xcodebuild -downloadPlatform iOS"
  PREFERRED_SIM="${FIRST_IPHONE}"
  SIM_UDID="$(sim_udid_for "${PREFERRED_SIM}")"
fi
[[ -n "${SIM_UDID}" ]] || fail "Could not resolve a simulator UDID."
echo "==> Using simulator: ${PREFERRED_SIM} (${SIM_UDID})"

if [[ ! -d "${BACKEND}/.venv" ]]; then
  fail "${BACKEND}/.venv missing. cd backend && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
fi

# shellcheck disable=SC1091
source "${BACKEND}/.venv/bin/activate"

echo "==> Starting backend on ${BASE_URL} (log: ${LOG})"
( cd "${BACKEND}" && exec uvicorn app.main:app --host 127.0.0.1 --port "${PORT}" >"${LOG}" 2>&1 ) &
BACKEND_PID=$!

cleanup() {
  echo "==> Stopping backend (pid ${BACKEND_PID})"
  kill -- "-${BACKEND_PID}" 2>/dev/null || kill "${BACKEND_PID}" 2>/dev/null || true
  pkill -f "uvicorn app.main:app --host 127.0.0.1 --port ${PORT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Waiting for /v1/health ..."
for i in $(seq 1 30); do
  curl -fsS "${BASE_URL}/health" >/dev/null 2>&1 && break
  kill -0 "${BACKEND_PID}" 2>/dev/null || { cat "${LOG}" >&2; fail "backend exited early"; }
  sleep 0.5
  [[ "${i}" == "30" ]] && { cat "${LOG}" >&2; fail "backend not healthy in time"; }
done
echo "==> Backend healthy."

echo "==> Booting ${PREFERRED_SIM} ..."
# Boot if not already booted (idempotent).
if ! xcrun simctl list devices 2>/dev/null | grep -F "${SIM_UDID}" | grep -q "(Booted)"; then
  xcrun simctl boot "${SIM_UDID}" 2>/dev/null || true
fi
open -a Simulator || true
# Give the simulator a moment to come up.
xcrun simctl bootstatus "${SIM_UDID}" -b >/dev/null 2>&1 || sleep 5

echo "==> flutter run on ${SIM_UDID} against ${BASE_URL} (Ctrl-C to stop; backend stops too)"
cd "${APP}"
flutter run -d "${SIM_UDID}" \
  --dart-define=TRADEWIZ_API_BASE_URL="${BASE_URL}"
