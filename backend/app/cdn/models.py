"""CDN data models (Phase B/C).

  * :class:`Manifest` — the small ``manifest.json`` the app downloads first to
    decide what (if anything) changed. Per-object content hashes drive delta
    downloads (Phase G): only objects whose hash changed are re-fetched.
  * :class:`PublishResult` — what a publish run uploaded / skipped, for
    scheduler logging and tests.
"""

from __future__ import annotations

from typing import Any, Dict, List

from pydantic import BaseModel, Field

# The nine supported markets (must match app.models.Market codes).
MARKETS: List[str] = [
    "IDX",
    "US",
    "JAPAN",
    "INDIA",
    "HKEX",
    "VIETNAM",
    "SINGAPORE",
    "KOSPI",
    "KOSDAQ",
]

# Global (market-independent) snapshot objects.
GLOBAL_OBJECTS: List[str] = [
    "dashboard",
    "rotation",
    "indices",
    "notifications",
    "daily_picks",
    "multibagger",
]

# Per-market snapshot objects.
MARKET_OBJECTS: List[str] = ["dashboard", "brief", "radar"]


class Manifest(BaseModel):
    """The change-detection manifest published to ``snapshots/manifest.json``.

    ``version`` is a coarse, human-readable build id (``YYYY.MM.DD.HHMM``).
    ``hashes`` maps every object's relative key to its sha256 content hash so
    the client can do a precise per-object delta (Phase G) regardless of the
    coarse version string.
    """

    version: str
    generated_at: str
    # Convenience top-level hashes mirrored into ``hashes`` for the docs/example.
    dashboard: str = ""
    rotation: str = ""
    indices: str = ""
    markets: Dict[str, str] = Field(default_factory=dict)
    # Full per-object content-hash map: relative key -> sha256 hex.
    # e.g. "global/dashboard.json", "markets/US/brief.json".
    hashes: Dict[str, str] = Field(default_factory=dict)
    # Per-object byte sizes (for the inspector / analytics).
    sizes: Dict[str, int] = Field(default_factory=dict)

    def changed_keys(self, other: "Manifest | None") -> List[str]:
        """Keys whose hash differs from ``other`` (or all keys if no prior)."""
        if other is None:
            return sorted(self.hashes.keys())
        changed: List[str] = []
        for key, h in self.hashes.items():
            if other.hashes.get(key) != h:
                changed.append(key)
        return sorted(changed)


class PublishResult(BaseModel):
    version: str
    uploaded: List[str] = Field(default_factory=list)
    skipped: List[str] = Field(default_factory=list)
    manifest_uploaded: bool = False
    invalidated: bool = False
    errors: Dict[str, str] = Field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return not self.errors

    def as_dict(self) -> Dict[str, Any]:
        return self.model_dump(mode="json")
