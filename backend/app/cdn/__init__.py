"""Global Snapshot CDN (Phase 7).

Publishes the server-generated snapshot documents to an object-storage CDN
(Cloudflare R2 by default, AWS S3 supported) so every user consumes the SAME
pre-computed snapshot from the edge instead of hitting the backend.

This package contains **no** scoring / ranking / accounting / market-universe
logic. It only takes the OUTPUT of the existing :mod:`app.snapshots` engine and
*delivers* it (serialize -> upload -> manifest). All investment logic stays
exactly where it already lives.

Layout published to the bucket::

    snapshots/
      manifest.json
      global/
        dashboard.json  rotation.json  indices.json
        notifications.json  daily_picks.json  multibagger.json
      markets/
        US/   dashboard.json  brief.json  radar.json
        IDX/  dashboard.json  brief.json  radar.json
        ...
"""

from .models import Manifest, PublishResult  # noqa: F401
from .storage import (  # noqa: F401
    SnapshotStorage,
    LocalStorage,
    R2Storage,
    S3Storage,
    build_storage_from_env,
)
from .publisher import SnapshotPublisher  # noqa: F401

__all__ = [
    "Manifest",
    "PublishResult",
    "SnapshotStorage",
    "LocalStorage",
    "R2Storage",
    "S3Storage",
    "build_storage_from_env",
    "SnapshotPublisher",
]
