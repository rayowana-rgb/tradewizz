"""Storage abstraction (Phase A).

A tiny, provider-agnostic object-storage interface so the publisher never knows
whether it's talking to Cloudflare R2, AWS S3, or a local directory.

  * :class:`SnapshotStorage` — abstract ``put_json`` / ``get_json`` / ``exists``
    / ``invalidate`` / ``public_url``.
  * :class:`LocalStorage` — filesystem backend (default for tests/dev).
  * :class:`R2Storage` — Cloudflare R2 (DEFAULT provider), S3-compatible API.
  * :class:`S3Storage` — AWS S3.

R2 and S3 share an S3-compatible client (``boto3``). ``boto3`` is an *optional*
dependency: if it is not installed we raise a clear error only when an R2/S3
backend is actually constructed, so local/dev and the test-suite never need it.

``build_storage_from_env()`` selects the backend from environment variables and
defaults to Cloudflare R2 when R2 credentials are present, else local.
"""

from __future__ import annotations

import abc
import json
import os
import threading
from typing import Any, Dict, List, Optional


class SnapshotStorage(abc.ABC):
    """Object storage for snapshot JSON documents."""

    #: Common key prefix for all snapshot objects in the bucket.
    prefix: str = "snapshots"

    @abc.abstractmethod
    def put_json(self, key: str, payload: Any) -> int:
        """Upload ``payload`` (a JSON-able object) at ``key``. Returns bytes."""

    @abc.abstractmethod
    def get_json(self, key: str) -> Optional[Any]:
        """Return the JSON object at ``key`` or ``None`` if missing/corrupt."""

    @abc.abstractmethod
    def exists(self, key: str) -> bool:
        ...

    def invalidate(self, keys: List[str]) -> bool:  # pragma: no cover - opt
        """Best-effort CDN cache invalidation. Returns True if attempted."""
        return False

    @abc.abstractmethod
    def public_url(self, key: str) -> str:
        ...

    # -- helpers -----------------------------------------------------------
    def _full_key(self, key: str) -> str:
        key = key.lstrip("/")
        if key.startswith(self.prefix + "/"):
            return key
        return f"{self.prefix}/{key}"

    @staticmethod
    def _encode(payload: Any) -> bytes:
        return json.dumps(payload, separators=(",", ":")).encode("utf-8")


class LocalStorage(SnapshotStorage):
    """Filesystem-backed storage (default for dev/tests).

    Mirrors the bucket layout under ``base_dir`` and serves files via
    ``public_url`` as ``file://`` paths (or a configured base url).
    """

    def __init__(self, base_dir: str, *, public_base: str = "") -> None:
        self._base = base_dir
        self._public_base = public_base.rstrip("/")
        self._lock = threading.RLock()
        os.makedirs(self._base, exist_ok=True)

    def _path(self, key: str) -> str:
        return os.path.join(self._base, self._full_key(key))

    def put_json(self, key: str, payload: Any) -> int:
        data = self._encode(payload)
        path = self._path(key)
        with self._lock:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "wb") as fh:
                fh.write(data)
            os.replace(tmp, path)
        return len(data)

    def get_json(self, key: str) -> Optional[Any]:
        path = self._path(key)
        try:
            with open(path, "rb") as fh:
                return json.loads(fh.read().decode("utf-8"))
        except (OSError, ValueError):
            return None

    def exists(self, key: str) -> bool:
        return os.path.exists(self._path(key))

    def public_url(self, key: str) -> str:
        full = self._full_key(key)
        if self._public_base:
            return f"{self._public_base}/{full}"
        return "file://" + os.path.abspath(self._path(key))


class _S3CompatStorage(SnapshotStorage):
    """Shared S3-compatible client used by both R2 and AWS S3."""

    def __init__(
        self,
        *,
        bucket: str,
        endpoint_url: Optional[str],
        access_key: str,
        secret_key: str,
        public_url: str,
        region: str = "auto",
        client: Any = None,
    ) -> None:
        self._bucket = bucket
        self._public = public_url.rstrip("/")
        if client is not None:
            self._client = client
        else:  # pragma: no cover - exercised only with real boto3
            try:
                import boto3  # type: ignore
            except ImportError as exc:  # noqa: F841
                raise RuntimeError(
                    "boto3 is required for R2/S3 uploads. Install boto3 or use "
                    "LocalStorage / set TRADEWIZZ_CDN_PROVIDER=local."
                )
            self._client = boto3.client(
                "s3",
                endpoint_url=endpoint_url,
                aws_access_key_id=access_key,
                aws_secret_access_key=secret_key,
                region_name=region,
            )

    def put_json(self, key: str, payload: Any) -> int:
        data = self._encode(payload)
        self._client.put_object(
            Bucket=self._bucket,
            Key=self._full_key(key),
            Body=data,
            ContentType="application/json",
            CacheControl="public, max-age=60",
        )
        return len(data)

    def get_json(self, key: str) -> Optional[Any]:
        try:
            resp = self._client.get_object(
                Bucket=self._bucket, Key=self._full_key(key)
            )
            body = resp["Body"].read()
            return json.loads(body.decode("utf-8"))
        except Exception:  # noqa: BLE001 — missing/corrupt -> None
            return None

    def exists(self, key: str) -> bool:
        try:
            self._client.head_object(
                Bucket=self._bucket, Key=self._full_key(key)
            )
            return True
        except Exception:  # noqa: BLE001
            return False

    def public_url(self, key: str) -> str:
        return f"{self._public}/{self._full_key(key)}"


class R2Storage(_S3CompatStorage):
    """Cloudflare R2 — the DEFAULT provider.

    R2 exposes an S3-compatible API at
    ``https://<account_id>.r2.cloudflarestorage.com``.
    """

    def __init__(
        self,
        *,
        account_id: str,
        access_key_id: str,
        secret_access_key: str,
        bucket: str,
        public_url: str,
        client: Any = None,
    ) -> None:
        endpoint = f"https://{account_id}.r2.cloudflarestorage.com"
        super().__init__(
            bucket=bucket,
            endpoint_url=endpoint,
            access_key=access_key_id,
            secret_key=secret_access_key,
            public_url=public_url,
            region="auto",
            client=client,
        )


class S3Storage(_S3CompatStorage):
    """AWS S3 backend."""

    def __init__(
        self,
        *,
        bucket: str,
        access_key_id: str,
        secret_access_key: str,
        public_url: str,
        region: str = "us-east-1",
        endpoint_url: Optional[str] = None,
        client: Any = None,
    ) -> None:
        super().__init__(
            bucket=bucket,
            endpoint_url=endpoint_url,
            access_key=access_key_id,
            secret_key=secret_access_key,
            public_url=public_url,
            region=region,
            client=client,
        )


def build_storage_from_env(
    env: Optional[Dict[str, str]] = None,
) -> SnapshotStorage:
    """Select a storage backend from the environment.

    Order of precedence:
      1. ``TRADEWIZZ_CDN_PROVIDER`` = ``r2`` | ``s3`` | ``local`` (explicit).
      2. R2 credentials present -> Cloudflare R2 (DEFAULT).
      3. S3 credentials present -> AWS S3.
      4. Fallback -> LocalStorage under ``data/cdn``.
    """
    env = env if env is not None else dict(os.environ)
    provider = (env.get("TRADEWIZZ_CDN_PROVIDER") or "").strip().lower()

    def _local() -> SnapshotStorage:
        here = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))
        base = env.get("TRADEWIZZ_CDN_DIR") or os.path.join(here, "data", "cdn")
        return LocalStorage(base, public_base=env.get("R2_PUBLIC_URL", ""))

    have_r2 = all(
        env.get(k)
        for k in ("R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID",
                  "R2_SECRET_ACCESS_KEY", "R2_BUCKET")
    )
    have_s3 = all(
        env.get(k)
        for k in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "S3_BUCKET")
    )

    if provider == "local":
        return _local()
    if provider == "r2" or (provider == "" and have_r2):
        if not have_r2:
            return _local()
        return R2Storage(
            account_id=env["R2_ACCOUNT_ID"],
            access_key_id=env["R2_ACCESS_KEY_ID"],
            secret_access_key=env["R2_SECRET_ACCESS_KEY"],
            bucket=env["R2_BUCKET"],
            public_url=env.get("R2_PUBLIC_URL", ""),
        )
    if provider == "s3" or (provider == "" and have_s3):
        if not have_s3:
            return _local()
        return S3Storage(
            bucket=env["S3_BUCKET"],
            access_key_id=env["AWS_ACCESS_KEY_ID"],
            secret_access_key=env["AWS_SECRET_ACCESS_KEY"],
            public_url=env.get("S3_PUBLIC_URL", ""),
            region=env.get("AWS_REGION", "us-east-1"),
            endpoint_url=env.get("S3_ENDPOINT_URL"),
        )
    return _local()
