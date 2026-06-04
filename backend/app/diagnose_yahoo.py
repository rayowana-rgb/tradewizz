"""Yahoo Finance data-source diagnostics.

Run: ``python -m app.diagnose_yahoo``

Reproduces the HTTP 429 issue and verifies the curl_cffi-impersonation fix.
Prints environment versions, a non-Yahoo control (SSL/network sanity), a raw
`requests` call (expected to 429 when the host is fingerprint-blocked), and a
curl_cffi Chrome-impersonated call (expected 200). Exit code 0 if impersonated
fetch works, 1 otherwise.
"""

from __future__ import annotations

import sys

CHART = (
    "https://query1.finance.yahoo.com/v8/finance/chart/AAPL"
    "?range=1mo&interval=1d"
)
CRUMB = "https://query2.finance.yahoo.com/v1/test/getcrumb"


def _versions() -> None:
    print("== environment ==")
    print(f"  python      {sys.version.split()[0]}")
    try:
        import ssl

        print(f"  ssl         {ssl.OPENSSL_VERSION}")
    except Exception as exc:  # noqa: BLE001
        print(f"  ssl         (error: {exc})")
    for mod in ("yfinance", "requests", "urllib3", "certifi", "curl_cffi"):
        try:
            m = __import__(mod)
            print(f"  {mod:11} {getattr(m, '__version__', '?')}")
        except Exception:  # noqa: BLE001
            print(f"  {mod:11} (not installed)")


def _control() -> None:
    print("\n== non-Yahoo control (SSL/network sanity) ==")
    try:
        import requests

        r = requests.get("https://httpbin.org/ip", timeout=10)
        print(f"  httpbin.org/ip -> {r.status_code}  {r.text.strip()[:60]}")
    except Exception as exc:  # noqa: BLE001
        print(f"  httpbin.org -> ERROR {exc}")


def _raw_requests() -> int:
    print("\n== raw requests (default TLS fingerprint) ==")
    try:
        import requests

        r = requests.get(CHART, timeout=10)
        print(f"  chart/AAPL -> {r.status_code}  {r.text[:50].strip()}")
        return r.status_code
    except Exception as exc:  # noqa: BLE001
        print(f"  chart/AAPL -> ERROR {exc}")
        return -1


def _impersonated() -> int:
    print("\n== curl_cffi (Chrome-impersonated TLS fingerprint) ==")
    try:
        from curl_cffi import requests as cffi

        s = cffi.Session(impersonate="chrome")
        rc = s.get(CRUMB, timeout=10)
        print(f"  getcrumb   -> {rc.status_code}  crumb={rc.text.strip()[:12]!r}")
        r = s.get(CHART, timeout=10)
        ok = r.status_code == 200 and '"chart"' in r.text
        print(f"  chart/AAPL -> {r.status_code}  {'OK (real JSON)' if ok else r.text[:50]}")
        return r.status_code
    except Exception as exc:  # noqa: BLE001
        print(f"  curl_cffi -> ERROR {exc}")
        return -1


def _engine_fetch() -> bool:
    print("\n== engine _yf_fetch (the real path) ==")
    ok = True
    try:
        from .engine import _yf_fetch

        for sym in ("AAPL", "BBCA.JK"):
            try:
                df = _yf_fetch(sym, "1mo", "1d")
                last = float(df["Close"].iloc[-1])
                print(f"  {sym:8} -> rows={len(df)} last_close={last:.2f}")
            except Exception as exc:  # noqa: BLE001
                ok = False
                print(f"  {sym:8} -> FAILED {type(exc).__name__}: {exc}")
    except Exception as exc:  # noqa: BLE001
        ok = False
        print(f"  import failed: {exc}")
    return ok


def main() -> int:
    _versions()
    _control()
    raw = _raw_requests()
    imp = _impersonated()
    engine_ok = _engine_fetch()

    print("\n== verdict ==")
    if raw == 429 and imp == 200:
        print("  Yahoo is fingerprint-blocking raw requests; curl_cffi bypasses it.")
    elif raw == 200:
        print("  Raw requests already work (host not currently blocked).")
    elif imp != 200:
        print("  curl_cffi did NOT get through -- block may be IP-wide or curl_cffi "
              "missing. Real data unavailable; engine will use mock fallback.")
    print(f"  engine _yf_fetch real data: {'YES' if engine_ok else 'NO'}")
    return 0 if engine_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
