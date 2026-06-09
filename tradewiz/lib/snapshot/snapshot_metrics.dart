/// Snapshot performance metrics (Phase M).
///
/// Lightweight, in-memory counters tracked per app session. They are surfaced
/// in the Snapshot Inspector (Phase L) and can be forwarded to analytics. We
/// deliberately keep this dependency-free so it works in tests and offline.
class SnapshotMetrics {
  int snapshotLoadCount = 0;
  int cacheHitCount = 0;
  int cacheMissCount = 0;
  int offlineLoadCount = 0;
  int refreshSuccessCount = 0;
  int refreshFailureCount = 0;

  // --- CDN counters (Phase 7 / Phase I) ---------------------------------
  int cdnManifestFetchCount = 0;
  int cdnSnapshotDownloadCount = 0;
  int cdnCacheHitCount = 0; // manifest unchanged -> served from Hive
  int cdnCacheMissCount = 0; // manifest changed -> downloaded
  int snapshotUpdateCount = 0;
  int snapshotBytes = 0;

  /// Rolling sum + count of successful refresh times (ms) -> average.
  int _loadTimeSumMs = 0;
  int _loadTimeSamples = 0;

  double get averageLoadTimeMs =>
      _loadTimeSamples == 0 ? 0 : _loadTimeSumMs / _loadTimeSamples;

  void cacheHit() {
    cacheHitCount++;
    snapshotLoadCount++;
  }

  void cacheMiss() {
    cacheMissCount++;
    snapshotLoadCount++;
  }

  void offlineLoad() => offlineLoadCount++;

  void refreshSuccess(int loadTimeMs) {
    refreshSuccessCount++;
    _loadTimeSumMs += loadTimeMs;
    _loadTimeSamples++;
  }

  void refreshFailure() => refreshFailureCount++;

  void cdnManifestFetch() => cdnManifestFetchCount++;
  void cdnCacheHit() => cdnCacheHitCount++;
  void cdnCacheMiss() => cdnCacheMissCount++;
  void cdnSnapshotDownload(int bytes) {
    cdnSnapshotDownloadCount++;
    snapshotBytes += bytes;
  }

  void snapshotUpdate() => snapshotUpdateCount++;

  Map<String, Object> toMap() => {
        'snapshot_load_time': averageLoadTimeMs,
        'snapshot_load_count': snapshotLoadCount,
        'cache_hit': cacheHitCount,
        'cache_miss': cacheMissCount,
        'offline_load': offlineLoadCount,
        'snapshot_refresh_success': refreshSuccessCount,
        'snapshot_refresh_failure': refreshFailureCount,
        'cdn_manifest_fetch': cdnManifestFetchCount,
        'cdn_snapshot_download': cdnSnapshotDownloadCount,
        'cdn_cache_hit': cdnCacheHitCount,
        'cdn_cache_miss': cdnCacheMissCount,
        'snapshot_update': snapshotUpdateCount,
        'snapshot_bytes': snapshotBytes,
        'offline_snapshot_load': offlineLoadCount,
      };

  void reset() {
    snapshotLoadCount = 0;
    cacheHitCount = 0;
    cacheMissCount = 0;
    offlineLoadCount = 0;
    refreshSuccessCount = 0;
    refreshFailureCount = 0;
    cdnManifestFetchCount = 0;
    cdnSnapshotDownloadCount = 0;
    cdnCacheHitCount = 0;
    cdnCacheMissCount = 0;
    snapshotUpdateCount = 0;
    snapshotBytes = 0;
    _loadTimeSumMs = 0;
    _loadTimeSamples = 0;
  }
}
