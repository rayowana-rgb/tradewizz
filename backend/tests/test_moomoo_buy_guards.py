"""Unit tests for the Opt-A live BUY guards on the REAL MoomooService.

Covers:
  * Position-count cap: opening a NEW name beyond the cap is blocked; adding to
    a held name (or a SELL) is always allowed.
  * Top-tier score guard: opening a NEW name whose engine score is below the
    floor is blocked; unknown score (None) is never blocked (no fabrication).

The network / SDK layer is never touched: preview() is pure, and place()'s
guards raise BEFORE the SDK import, so we assert the guard rejection.
"""

import pytest

from app.moomoo.service import MoomooService, MoomooError, MoomooPosition


class _Match:
    def __init__(self, score):
        self.score = score


def _svc(held, *, cap_positions="50", min_score="80", scores=None):
    """A real MoomooService with positions() and score provider stubbed."""
    svc = MoomooService()
    svc.positions = lambda: [  # type: ignore[method-assign]
        MoomooPosition(f"US.{s}", s, 1.0, 1.0, 100.0, 100.0, 0.0, 0.0)
        for s in held
    ]
    # Cheap est_notional so nothing trips the notional cap.
    svc._est_notional = lambda code, qty, price: 10.0  # type: ignore
    scores = scores or {}
    svc.set_score_provider(lambda sym, market: (
        _Match(scores[sym]) if sym in scores else None
    ))
    return svc, {"cap_positions": cap_positions, "min_score": min_score}


def _env(monkeypatch, cfg):
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_MAX_POSITIONS", cfg["cap_positions"])
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_MIN_BUY_SCORE", cfg["min_score"])


# --- Position-count cap ----------------------------------------------------

def test_new_buy_blocked_at_position_cap(monkeypatch):
    held = [f"S{i}" for i in range(3)]
    svc, cfg = _svc(held, cap_positions="3", scores={"NEW": 95})
    _env(monkeypatch, cfg)
    pv = svc.preview("NEW", "BUY", 1.0, "MARKET", None)
    assert pv["held_count"] == 3
    assert pv["is_new_position"] is True
    assert pv["at_position_cap"] is True
    with pytest.raises(MoomooError) as e:
        svc.place("NEW", "BUY", 1.0, "MARKET", None, confirm=True,
                  trade_pin="000000")
    assert e.value.status_code == 403
    assert "position cap" in str(e.value).lower()


def test_adding_to_held_name_allowed_at_cap(monkeypatch):
    held = ["AAPL", "MSFT", "NVDA"]
    svc, cfg = _svc(held, cap_positions="3", scores={"AAPL": 30})
    _env(monkeypatch, cfg)
    pv = svc.preview("AAPL", "BUY", 1.0, "MARKET", None)
    assert pv["is_new_position"] is False
    assert pv["at_position_cap"] is False
    assert pv["below_min_score"] is False  # held name -> score guard skipped


def test_sell_never_hits_position_cap(monkeypatch):
    held = [f"S{i}" for i in range(60)]
    svc, cfg = _svc(held, cap_positions="50")
    _env(monkeypatch, cfg)
    pv = svc.preview("S0", "SELL", 1.0, "MARKET", None)
    assert pv["at_position_cap"] is False


# --- Top-tier score guard --------------------------------------------------

def test_new_buy_below_min_score_blocked(monkeypatch):
    svc, cfg = _svc(["HELD"], cap_positions="50", min_score="80",
                    scores={"WEAK": 55})
    _env(monkeypatch, cfg)
    pv = svc.preview("WEAK", "BUY", 1.0, "MARKET", None)
    assert pv["new_buy_score"] == 55
    assert pv["below_min_score"] is True
    with pytest.raises(MoomooError) as e:
        svc.place("WEAK", "BUY", 1.0, "MARKET", None, confirm=True,
                  trade_pin="000000")
    assert e.value.status_code == 403
    assert "top-tier" in str(e.value).lower()


def test_new_buy_top_tier_allowed(monkeypatch):
    svc, cfg = _svc(["HELD"], cap_positions="50", min_score="80",
                    scores={"STRONG": 88})
    _env(monkeypatch, cfg)
    pv = svc.preview("STRONG", "BUY", 1.0, "MARKET", None)
    assert pv["new_buy_score"] == 88
    assert pv["below_min_score"] is False


def test_unknown_score_is_not_blocked(monkeypatch):
    # No score provider entry -> None -> we never fabricate a rejection.
    svc, cfg = _svc(["HELD"], cap_positions="50", min_score="80", scores={})
    _env(monkeypatch, cfg)
    pv = svc.preview("MYSTERY", "BUY", 1.0, "MARKET", None)
    assert pv["new_buy_score"] is None
    assert pv["below_min_score"] is False


def test_guards_disabled_when_zero(monkeypatch):
    held = [f"S{i}" for i in range(60)]
    svc, cfg = _svc(held, cap_positions="0", min_score="0",
                    scores={"WEAK": 10})
    _env(monkeypatch, cfg)
    pv = svc.preview("WEAK", "BUY", 1.0, "MARKET", None)
    assert pv["at_position_cap"] is False
    assert pv["below_min_score"] is False
