"""Snapshot publisher (Phase A/B/C/D).

Turns the OUTPUT of :class:`app.snapshots.service.SnapshotService` into the
published CDN layout and uploads it through a :class:`SnapshotStorage` backend.

Responsibilities:
  * Build the per-object documents (global + per-market) from already-computed
    snapshots — NO scoring/ranking/accounting here.
  * Compute a content hash per object and emit ``manifest.json`` (Phase C).
  * Upload only objects whose hash changed since the last manifest (delta).
  * Validate every object before upload (Phase K): non-empty, JSON-able,
    required sections present — never publish a corrupt/partial document.
  * Optionally invalidate the CDN cache for changed objects (Phase D).

Publishing is only ever invoked by the scheduler (Phase D) — never by a user
request.
"""

from __future__ import annotations

import hashlib
import json
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from ..models import Market
from ..snapshots.service import SnapshotService
from .models import GLOBAL_OBJECTS, MARKET_OBJECTS, MARKETS, Manifest, PublishResult
from .storage import SnapshotStorage

MANIFEST_KEY = "manifest.json"

# Required top-level sections per object kind (Phase K corruption guard).
_REQUIRED: Dict[str, List[str]] = {
    "dashboard": ["generated_at", "market"],
    "rotation": [],
    "indices": [],
    "brief": [],
    "radar": [],
    "notifications": [],
    "daily_picks": [],
    "multibagger": [],
}


# Envelope fields that change on every build even when the meaningful content
# is identical. They are excluded from the content hash so delta detection
# (Phase G) only fires on REAL data changes, not fresh timestamps.
_VOLATILE = ("generated_at", "section_ages")


def _strip_volatile(payload: Any) -> Any:
    if isinstance(payload, dict):
        return {
            k: _strip_volatile(v)
            for k, v in payload.items()
            if k not in _VOLATILE
        }
    if isinstance(payload, list):
        return [_strip_volatile(v) for v in payload]
    return payload


def _hash(payload: Any) -> str:
    raw = json.dumps(
        _strip_volatile(payload), sort_keys=True, separators=(",", ":")
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _version(now: Optional[float] = None) -> str:
    dt = datetime.fromtimestamp(now, tz=timezone.utc) if now else \
        datetime.now(timezone.utc)
    return dt.strftime("%Y.%m.%d.%H%M")


class SnapshotPublisher:
    def __init__(
        self,
        service: SnapshotService,
        storage: SnapshotStorage,
        *,
        markets: Optional[List[str]] = None,
        clock=time.time,
    ) -> None:
        self._svc = service
        self._storage = storage
        self._markets = markets or list(MARKETS)
        self._clock = clock

    # -- object assembly ----------------------------------------------------
    def _build_objects(self) -> Dict[str, Any]:
        """Return ``{relative_key: payload}`` for every object to publish.

        Built entirely from the snapshot service OUTPUT; the dashboard snapshot
        already contains every section, so we slice it rather than recompute.
        """
        objects: Dict[str, Any] = {}

        # Use a representative market (US) to harvest the GLOBAL sections, which
        # are market-independent in the snapshot service (indices/rotation/...).
        base = self._svc.dashboard(Market.US).model_dump(mode="json")

        objects["global/dashboard.json"] = base
        objects["global/rotation.json"] = base.get("rotation") or {}
        objects["global/indices.json"] = base.get("indices") or {}
        objects["global/notifications.json"] = base.get("notifications") or {}
        objects["global/daily_picks.json"] = base.get("daily_picks") or {}
        objects["global/multibagger.json"] = base.get("multibagger") or {}

        # Per-market sections: each market's dashboard, brief and radar.
        for code in self._markets:
            try:
                mk = Market(code)
            except ValueError:
                continue
            snap = self._svc.dashboard(mk).model_dump(mode="json")
            objects[f"markets/{code}/dashboard.json"] = snap
            objects[f"markets/{code}/brief.json"] = snap.get("morning_brief") or {}
            objects[f"markets/{code}/radar.json"] = snap.get("radar") or {}
        return objects

    # -- Phase K: validation ------------------------------------------------
    @staticmethod
    def _kind(key: str) -> str:
        # "global/rotation.json" -> "rotation"; "markets/US/brief.json" -> "brief"
        leaf = key.rsplit("/", 1)[-1]
        return leaf[:-5] if leaf.endswith(".json") else leaf

    def _valid(self, key: str, payload: Any) -> bool:
        """Never publish null / empty / partial / non-JSON-able documents."""
        if payload is None:
            return False
        if isinstance(payload, dict):
            if not payload:
                return False
            if payload.get("error") is not None:
                return False
            for field in _REQUIRED.get(self._kind(key), []):
                if field not in payload:
                    return False
        try:
            json.dumps(payload)
        except (TypeError, ValueError):
            return False
        return True

    # -- Phase C: manifest --------------------------------------------------
    def _read_remote_manifest(self) -> Optional[Manifest]:
        raw = self._storage.get_json(MANIFEST_KEY)
        if not isinstance(raw, dict):
            return None
        try:
            return Manifest(**raw)
        except Exception:  # noqa: BLE001
            return None

    def build_manifest(
        self, objects: Dict[str, Any], *, version: Optional[str] = None
    ) -> Manifest:
        hashes = {k: _hash(v) for k, v in objects.items()}
        sizes = {
            k: len(json.dumps(v, separators=(",", ":")).encode("utf-8"))
            for k, v in objects.items()
        }
        markets = {
            code: hashes.get(f"markets/{code}/dashboard.json", "")
            for code in self._markets
        }
        return Manifest(
            version=version or _version(self._clock()),
            generated_at=datetime.now(timezone.utc).isoformat(),
            dashboard=hashes.get("global/dashboard.json", ""),
            rotation=hashes.get("global/rotation.json", ""),
            indices=hashes.get("global/indices.json", ""),
            markets=markets,
            hashes=hashes,
            sizes=sizes,
        )

    # -- Phase D: publish ---------------------------------------------------
    def publish(self, *, invalidate: bool = False) -> PublishResult:
        """Build + upload changed objects + the manifest. Scheduler-only."""
        objects = self._build_objects()
        manifest = self.build_manifest(objects)
        result = PublishResult(version=manifest.version)

        previous = self._read_remote_manifest()
        changed = set(manifest.changed_keys(previous))

        for key, payload in objects.items():
            # Phase K: validate before replacing anything.
            if not self._valid(key, payload):
                result.skipped.append(key)
                result.errors[key] = "invalid/empty payload (kept previous)"
                # Reuse the previous hash so the manifest doesn't claim a change.
                if previous and key in previous.hashes:
                    manifest.hashes[key] = previous.hashes[key]
                continue
            if key not in changed:
                result.skipped.append(key)
                continue
            try:
                self._storage.put_json(key, payload)
                result.uploaded.append(key)
            except Exception as exc:  # noqa: BLE001
                result.errors[key] = str(exc)
                if previous and key in previous.hashes:
                    manifest.hashes[key] = previous.hashes[key]

        # Always (re)write the manifest last so clients only see complete sets.
        try:
            self._storage.put_json(MANIFEST_KEY, manifest.model_dump(mode="json"))
            result.manifest_uploaded = True
        except Exception as exc:  # noqa: BLE001
            result.errors[MANIFEST_KEY] = str(exc)

        if invalidate and result.uploaded:
            try:
                result.invalidated = self._storage.invalidate(
                    result.uploaded + [MANIFEST_KEY]
                )
            except Exception:  # noqa: BLE001
                result.invalidated = False

        return result

    def public_manifest_url(self) -> str:
        return self._storage.public_url(MANIFEST_KEY)
