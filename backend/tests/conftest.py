"""Shared pytest fixtures: keep the suite hermetic and repo-clean."""

import os
import tempfile

import pytest


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
