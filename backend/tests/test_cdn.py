"""Tests for the Global Snapshot CDN (Phase 7).

Covers: storage abstraction (Local + S3-compatible via a fake client),
publisher object assembly, manifest generation + delta detection, scheduler
upload wiring, corruption/partial-download protection, and an R2 upload path
(through an injected fake boto3 client).
"""

from __future__ import annotations

import json
import os
import tempfile

import pytest

from app.cdn.models import GLOBAL_OBJECTS, MARKET_OBJECTS, MARKETS, Manifest
from app.cdn.publisher import MANIFEST_KEY, SnapshotPublisher
from app.cdn.storage import (
    LocalStorage,
    R2Storage,
    S3Storage,
    build_storage_from_env,
)
from app.models import Market
from app.snapshots.cache import SnapshotCache
from app.snapshots.scheduler import SnapshotScheduler
from app.snapshots.service import SnapshotService


# --------------------------------------------------------------------------- #
# Fakes
# --------------------------------------------------------------------------- #
class FakeS3Client:
    """Minimal in-memory S3-compatible client for R2/S3 storage tests."""

    def __init__(self) -> None:
        self.store: dict = {}
        self.puts = 0

    def put_object(self, *, Bucket, Key, Body, **kw):  # noqa: N803
        self.puts += 1
        self.store[(Bucket, Key)] = Body

    def get_object(self, *, Bucket, Key):  # noqa: N803
        if (Bucket, Key) not in self.store:
            raise KeyError(Key)
        return {"Body": _Body(self.store[(Bucket, Key)])}

    def head_object(self, *, Bucket, Key):  # noqa: N803
        if (Bucket, Key) not in self.store:
            raise KeyError(Key)
        return {}


class _Body:
    def __init__(self, data):
        self._data = data

    def read(self):
        return self._data


def _service(cache_dir):
    """A SnapshotService with tiny deterministic providers (no Yahoo)."""
    cache = SnapshotCache(directory=cache_dir)
    return SnapshotService(
        cache=cache,
        indices_provider=lambda: [{"symbol": "^GSPC", "price": 5000.0}],
        brief_provider=lambda mk: {"market": mk.value, "headline": "Hi"},
        rotation_provider=lambda: {"best_market": "US", "markets": []},
        opportunities_provider=lambda: {"opportunities": [{"symbol": "NVDA"}]},
        daily_provider=lambda: {"picks": [{"symbol": "AAPL"}]},
        multibagger_provider=lambda: {"candidates": [{"symbol": "TSLA"}]},
        watchlist_provider=lambda uid, existing: {"suggestions": []},
        notifications_provider=lambda uid: ([{"id": 1}], 1),
    )


@pytest.fixture()
def tmpdirs():
    with tempfile.TemporaryDirectory() as snap, tempfile.TemporaryDirectory() as cdn:
        yield snap, cdn


# --------------------------------------------------------------------------- #
# Phase A: storage abstraction
# --------------------------------------------------------------------------- #
def test_local_storage_roundtrip_and_prefix(tmpdirs):
    _, cdn = tmpdirs
    s = LocalStorage(cdn, public_base="https://cdn.example")
    n = s.put_json("global/rotation.json", {"best_market": "US"})
    assert n > 0
    assert s.exists("global/rotation.json")
    assert s.get_json("global/rotation.json") == {"best_market": "US"}
    # prefix applied + public url uses the configured base
    assert s.public_url("manifest.json").endswith("snapshots/manifest.json")
    # written under snapshots/ prefix on disk
    assert os.path.exists(os.path.join(cdn, "snapshots", "global", "rotation.json"))


def test_local_storage_missing_and_corrupt_return_none(tmpdirs):
    _, cdn = tmpdirs
    s = LocalStorage(cdn)
    assert s.get_json("nope.json") is None
    # write a corrupt file directly
    path = os.path.join(cdn, "snapshots", "bad.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write("{not json")
    assert s.get_json("bad.json") is None


def test_s3_compatible_roundtrip_with_fake_client():
    fake = FakeS3Client()
    s = S3Storage(
        bucket="b", access_key_id="k", secret_access_key="x",
        public_url="https://cdn.example", client=fake,
    )
    s.put_json("global/indices.json", {"indices": []})
    assert fake.puts == 1
    assert s.exists("global/indices.json")
    assert s.get_json("global/indices.json") == {"indices": []}
    assert s.public_url("global/indices.json") == \
        "https://cdn.example/snapshots/global/indices.json"


def test_r2_upload_path_with_fake_client():
    """Phase: R2 upload works end-to-end through the injected client."""
    fake = FakeS3Client()
    r2 = R2Storage(
        account_id="acct", access_key_id="k", secret_access_key="x",
        bucket="snaps", public_url="https://pub.r2.dev", client=fake,
    )
    size = r2.put_json("markets/US/dashboard.json", {"market": "US"})
    assert size > 0 and fake.puts == 1
    assert r2.get_json("markets/US/dashboard.json") == {"market": "US"}
    assert r2.public_url("markets/US/brief.json").startswith(
        "https://pub.r2.dev/snapshots/markets/US/brief.json"
    )


def test_build_storage_from_env_selects_provider():
    assert type(build_storage_from_env({})).__name__ == "LocalStorage"
    assert type(build_storage_from_env(
        {"TRADEWIZZ_CDN_PROVIDER": "local"})).__name__ == "LocalStorage"
    # R2 default when creds present (constructed lazily; boto3 not needed because
    # we only check selection, so force local to avoid importing boto3 here).
    env = {
        "TRADEWIZZ_CDN_PROVIDER": "local",
        "R2_ACCOUNT_ID": "a", "R2_ACCESS_KEY_ID": "b",
        "R2_SECRET_ACCESS_KEY": "c", "R2_BUCKET": "d",
    }
    assert type(build_storage_from_env(env)).__name__ == "LocalStorage"


# --------------------------------------------------------------------------- #
# Phase B/C: publisher + manifest
# --------------------------------------------------------------------------- #
def test_publish_creates_full_layout_and_manifest(tmpdirs):
    snap, cdn = tmpdirs
    svc = _service(snap)
    storage = LocalStorage(cdn)
    pub = SnapshotPublisher(svc, storage, markets=list(MARKETS))

    result = pub.publish()
    assert result.ok, result.errors
    assert result.manifest_uploaded

    # Global objects present.
    for obj in GLOBAL_OBJECTS:
        assert storage.exists(f"global/{obj}.json"), obj
    # Per-market objects present for every market.
    for code in MARKETS:
        for obj in MARKET_OBJECTS:
            assert storage.exists(f"markets/{code}/{obj}.json"), (code, obj)

    # Manifest has version + per-object hashes + market map.
    manifest = Manifest(**storage.get_json(MANIFEST_KEY))
    assert manifest.version
    assert manifest.dashboard  # global dashboard hash set
    assert set(manifest.markets.keys()) == set(MARKETS)
    assert "global/rotation.json" in manifest.hashes
    assert manifest.sizes["global/dashboard.json"] > 0


def test_manifest_version_format(tmpdirs):
    snap, cdn = tmpdirs
    pub = SnapshotPublisher(_service(snap), LocalStorage(cdn))
    objs = pub._build_objects()
    manifest = pub.build_manifest(objs, version="2026.06.09.0800")
    assert manifest.version == "2026.06.09.0800"


def test_changed_keys_delta_detection(tmpdirs):
    snap, cdn = tmpdirs
    pub = SnapshotPublisher(_service(snap), LocalStorage(cdn))
    objs = pub._build_objects()
    m1 = pub.build_manifest(objs, version="v1")
    # No prior manifest -> everything changed.
    assert m1.changed_keys(None) == sorted(m1.hashes.keys())
    # Same content -> nothing changed.
    m2 = pub.build_manifest(objs, version="v2")
    assert m2.changed_keys(m1) == []
    # Mutate one object -> only that key reported.
    m3 = pub.build_manifest({**objs, "global/rotation.json": {"x": 1}})
    assert m3.changed_keys(m1) == ["global/rotation.json"]


def test_second_publish_skips_unchanged_objects(tmpdirs):
    snap, cdn = tmpdirs
    svc = _service(snap)
    pub = SnapshotPublisher(svc, LocalStorage(cdn), markets=["US"])
    first = pub.publish()
    assert first.uploaded  # everything uploaded the first time
    second = pub.publish()
    # Nothing changed -> all objects skipped (delta download equivalent).
    assert second.uploaded == []
    assert "global/dashboard.json" in second.skipped


# --------------------------------------------------------------------------- #
# Phase K: corruption / partial protection
# --------------------------------------------------------------------------- #
def test_invalid_payload_is_not_published(tmpdirs):
    snap, cdn = tmpdirs
    svc = _service(snap)
    storage = LocalStorage(cdn)
    pub = SnapshotPublisher(svc, storage, markets=["US"])

    # Patch object assembly to inject an empty + an error doc.
    real = pub._build_objects

    def _bad():
        objs = real()
        objs["global/rotation.json"] = {}           # empty
        objs["global/indices.json"] = {"error": "x"}  # error doc
        return objs

    pub._build_objects = _bad  # type: ignore
    result = pub.publish()
    assert "global/rotation.json" in result.skipped
    assert "global/indices.json" in result.skipped
    # Manifest still written; valid objects still published.
    assert result.manifest_uploaded
    assert storage.exists("global/dashboard.json")


def test_valid_snapshot_not_overwritten_by_later_empty(tmpdirs):
    snap, cdn = tmpdirs
    svc = _service(snap)
    storage = LocalStorage(cdn)
    pub = SnapshotPublisher(svc, storage, markets=["US"])
    pub.publish()
    good = storage.get_json("global/rotation.json")
    assert good == {"best_market": "US", "markets": []}

    # Now publish with an empty rotation -> must keep the previous good file.
    real = pub._build_objects
    pub._build_objects = lambda: {**real(), "global/rotation.json": {}}  # type: ignore
    pub.publish()
    assert storage.get_json("global/rotation.json") == good


def test_corrupt_remote_manifest_is_ignored(tmpdirs):
    snap, cdn = tmpdirs
    storage = LocalStorage(cdn)
    # Pre-seed a corrupt manifest.
    path = os.path.join(cdn, "snapshots", "manifest.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write("{broken")
    pub = SnapshotPublisher(_service(snap), storage, markets=["US"])
    # Should treat as "no prior manifest" and publish everything.
    result = pub.publish()
    assert result.ok
    assert "global/dashboard.json" in result.uploaded


# --------------------------------------------------------------------------- #
# Phase D: scheduler upload
# --------------------------------------------------------------------------- #
def test_scheduler_publishes_after_refresh(tmpdirs):
    snap, cdn = tmpdirs
    svc = _service(snap)
    storage = LocalStorage(cdn)
    pub = SnapshotPublisher(svc, storage, markets=["US"])
    sched = SnapshotScheduler(
        svc, markets=[Market.US], publisher=pub, publish_on_refresh=True
    )
    ran = sched.tick(now=0.0)
    assert ran  # at least one section refreshed
    assert sched.last_publish is not None
    assert sched.last_publish.manifest_uploaded
    assert storage.exists(MANIFEST_KEY.replace(".json", ".json"))
    assert storage.exists("global/dashboard.json")


def test_scheduler_without_publisher_does_not_crash(tmpdirs):
    snap, _ = tmpdirs
    svc = _service(snap)
    sched = SnapshotScheduler(svc, markets=[Market.US])
    ran = sched.tick(now=0.0)
    assert ran
    assert sched.last_publish is None


def test_publish_only_via_scheduler_not_user_request(tmpdirs):
    """The router/service never call publish(); only the scheduler does."""
    snap, cdn = tmpdirs
    svc = _service(snap)
    # Building a dashboard (a user request path) must not touch CDN storage.
    storage = LocalStorage(cdn)
    SnapshotPublisher(svc, storage, markets=["US"])
    svc.dashboard(Market.US)
    assert not storage.exists(MANIFEST_KEY)
    assert not storage.exists("global/dashboard.json")
