"""Shared pytest fixtures: keep the suite hermetic and repo-clean."""

import os
import tempfile

import pytest

# Point the market-close screener cache at a throwaway SQLite file BEFORE any
# test module imports app.main (which reads this env var at import time). Keeps
# the cache out of the repo's .cache/ and makes runs independent.
if "TRADEWIZ_SCREENER_CACHE_DB" not in os.environ:
    _tw_screener_cache_dir = tempfile.mkdtemp(prefix="tw_test_screener_")
    os.environ["TRADEWIZ_SCREENER_CACHE_DB"] = os.path.join(
        _tw_screener_cache_dir, "screener_snapshots.db"
    )


@pytest.fixture(autouse=True)
def _reset_screener_cache_global_state():
    """Clear screener-cache module globals between tests.

    The write-time rebuild cooldown (``_rebuild_seen``) is process-global and
    keyed by (market, cache_key, date); without a per-test reset, one test's
    rebuild would suppress another's via the cooldown.
    """
    try:
        from app.screener_cache.service import (
            reset_rebuild_cooldown,
            invalidate_freshness_probe_cache,
        )
        reset_rebuild_cooldown()
        invalidate_freshness_probe_cache()
    except Exception:  # noqa: BLE001 - app may not be importable in some tests
        pass
    yield


@pytest.fixture(autouse=True, scope="session")
def _isolated_model_dir():
    """Point the RandomForest model cache at a throwaway dir for the whole run.

    Prevents tests that call `engine.analyze()` from writing model `.pkl` files
    into the repo's `.cache/rf_models`, and keeps runs independent.
    """
    prev = os.environ.get("TRADEWIZ_MODEL_DIR")
    tmp = tempfile.mkdtemp(prefix="tw_test_models_")
    os.environ["TRADEWIZ_MODEL_DIR"] = tmp
    try:
        yield
    finally:
        if prev is None:
            os.environ.pop("TRADEWIZ_MODEL_DIR", None)
        else:
            os.environ["TRADEWIZ_MODEL_DIR"] = prev
