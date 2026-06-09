"""Trading-date-aware freshness policy for the fallback cache.

The TTL cache answers "is this entry within its TTL?". Freshness answers a
stricter, market-aware question: *given the current session state and the
trading date the entry was built for, may this cached value be treated as
FRESH (safe to score/rank on), only DISPLAYED (shown but never scored), or not
used at all?*

This is intentionally separate from the value cache so the same decision logic
can guard Morning Brief, Rotation, Radar, Auto Watchlist and Notifications.

Rules (per the freshness spec)
------------------------------
1. Market OPEN, same trading_date:
     * fallback allowed only if age <= ``OPEN_FALLBACK_MAX_AGE`` (30 min).
       -> fresh path normally; if rebuild fails and age <= 30m, serve
          fallback marked ``fallback=True, stale=True``.
       -> if age > 30m: NOT usable; caller returns partial-unavailable.
2. Market CLOSED, same trading_date:
     * fallback may be used safely -> ``freshness="last_close"`` (not stale).
3. New calendar day but PRE_MARKET:
     * previous trading day's cache usable as last close ->
       ``freshness="previous_close"`` (not stale; it's the correct last close).
4. Market OPEN on a NEW trading_date (entry built for a prior trading date):
     * previous-day cache must NOT be treated as fresh current data; only as a
       last_close reference if current data is unavailable ->
       ``stale=True, fallback=True, freshness="previous_close"`` and
       ``usable_as_fresh=False``.
5. Stale fallback may be DISPLAYED only, never used for scoring / radar /
   morning brief / auto watchlist / rotation / notifications. That is encoded
   as ``usable_as_fresh=False`` whenever ``stale`` is True.

``usable_as_fresh`` is the single gate scoring paths must honour.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from typing import Optional

from ..market_session import (
    MarketSessionState,
    current_trading_date,
    get_market_session_state,
    market_now,
)

# Max age a fallback entry may have while the market is OPEN and on the same
# trading date (seconds).
OPEN_FALLBACK_MAX_AGE = 30 * 60  # 30 minutes


@dataclass(frozen=True)
class FreshnessDecision:
    """Outcome of evaluating a cache entry against the freshness policy.

    Attributes
    ----------
    usable_as_fresh:
        True only when the value may be used for scoring / ranking / radar /
        brief / watchlist / rotation / notifications. This is the gate.
    usable_as_display:
        True when the value may be shown to the user (even if not fresh).
    stale:
        True when the value is older than the policy allows for "fresh".
    fallback:
        True when the value is being offered as a fallback (rebuild failed or
        is being skipped), rather than as a normal live build.
    freshness:
        Human/machine label: "live" | "last_close" | "previous_close" |
        "stale" | "unavailable".
    session_state:
        The market session state used for the decision.
    age_seconds:
        Age of the cache entry in seconds (None when no entry).
    reason:
        Short explanation, useful for logs / debug endpoints.
    """

    usable_as_fresh: bool
    usable_as_display: bool
    stale: bool
    fallback: bool
    freshness: str
    session_state: MarketSessionState
    age_seconds: Optional[float]
    reason: str


def _resolve_now(market, now: Optional[datetime]) -> datetime:
    return now if now is not None else market_now(market)


def evaluate(
    market,
    *,
    entry_trading_date: Optional[date],
    entry_cached_at_epoch: Optional[float],
    now: Optional[datetime] = None,
    now_epoch: Optional[float] = None,
) -> FreshnessDecision:
    """Decide how a cached entry may be used right now.

    Parameters
    ----------
    market:
        Market enum or code.
    entry_trading_date:
        The trading date the cached entry was built for (``None`` if no entry).
    entry_cached_at_epoch:
        Wall-clock epoch seconds when the entry was built (``None`` if none).
    now / now_epoch:
        Injectable clock(s) for tests. ``now`` drives session classification;
        ``now_epoch`` drives age. When omitted they are derived from the
        market clock / ``now``.
    """
    mnow = _resolve_now(market, now)
    state = get_market_session_state(market, mnow)
    today_trading_date = current_trading_date(market, mnow)

    # No entry at all -> nothing to serve.
    if entry_trading_date is None or entry_cached_at_epoch is None:
        return FreshnessDecision(
            usable_as_fresh=False, usable_as_display=False, stale=False,
            fallback=False, freshness="unavailable", session_state=state,
            age_seconds=None, reason="no cache entry",
        )

    if now_epoch is None:
        now_epoch = mnow.timestamp()
    age = max(0.0, now_epoch - entry_cached_at_epoch)

    same_trading_date = entry_trading_date == today_trading_date

    # --- Market CLOSED -------------------------------------------------
    if state is MarketSessionState.CLOSED:
        if same_trading_date:
            # Rule 2: same-day closed fallback is safe.
            return FreshnessDecision(
                usable_as_fresh=True, usable_as_display=True, stale=False,
                fallback=False, freshness="last_close", session_state=state,
                age_seconds=age, reason="closed, same trading_date",
            )
        # Closed but entry is from an older trading date: it's the last close
        # reference, display-only (not used to score current data).
        return FreshnessDecision(
            usable_as_fresh=False, usable_as_display=True, stale=True,
            fallback=True, freshness="previous_close", session_state=state,
            age_seconds=age, reason="closed, older trading_date",
        )

    # --- Market PRE_MARKET --------------------------------------------
    if state is MarketSessionState.PRE_MARKET:
        # Rule 3: previous trading day's cache is the correct last close and
        # may be used. (Same-date pre-market only happens if data was built
        # during pre-market; treat as last_close too.)
        if same_trading_date:
            return FreshnessDecision(
                usable_as_fresh=True, usable_as_display=True, stale=False,
                fallback=False, freshness="last_close", session_state=state,
                age_seconds=age, reason="pre-market, same trading_date",
            )
        return FreshnessDecision(
            usable_as_fresh=True, usable_as_display=True, stale=False,
            fallback=True, freshness="previous_close", session_state=state,
            age_seconds=age, reason="pre-market, previous trading day's close",
        )

    # --- Market OPEN (or POST_MARKET treated like OPEN for freshness) ---
    # POST_MARKET: regular session just ended; same-date entry is the close.
    if state is MarketSessionState.POST_MARKET:
        if same_trading_date:
            return FreshnessDecision(
                usable_as_fresh=True, usable_as_display=True, stale=False,
                fallback=False, freshness="last_close", session_state=state,
                age_seconds=age, reason="post-market, same trading_date",
            )
        return FreshnessDecision(
            usable_as_fresh=False, usable_as_display=True, stale=True,
            fallback=True, freshness="previous_close", session_state=state,
            age_seconds=age, reason="post-market, older trading_date",
        )

    # state is OPEN
    if same_trading_date:
        # Rule 1: same-day open. Fresh if young enough; otherwise stale and
        # only usable as a <=30m display fallback when rebuild fails.
        if age <= OPEN_FALLBACK_MAX_AGE:
            return FreshnessDecision(
                usable_as_fresh=True, usable_as_display=True, stale=False,
                fallback=False, freshness="live", session_state=state,
                age_seconds=age, reason="open, same trading_date, fresh",
            )
        return FreshnessDecision(
            usable_as_fresh=False, usable_as_display=False, stale=True,
            fallback=True, freshness="stale", session_state=state,
            age_seconds=age,
            reason="open, same trading_date, age > 30m -> unavailable",
        )

    # Rule 4: OPEN on a NEW trading_date. Previous-day cache must NOT be fresh
    # current data; only a last_close reference, display-only.
    return FreshnessDecision(
        usable_as_fresh=False, usable_as_display=True, stale=True,
        fallback=True, freshness="previous_close", session_state=state,
        age_seconds=age,
        reason="open, new trading_date -> previous_close reference only",
    )
