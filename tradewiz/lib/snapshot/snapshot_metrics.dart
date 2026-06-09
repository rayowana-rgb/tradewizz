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

  Map<String, Object> toMap() => {
        'snapshot_load_time': averageLoadTimeMs,
        'snapshot_load_count': snapshotLoadCount,
        'cache_hit': cacheHitCount,
        'cache_miss': cacheMissCount,
        'offline_load': offlineLoadCount,
        'snapshot_refresh_success': refreshSuccessCount,
        'snapshot_refresh_failure': refreshFailureCount,
      };

  void reset() {
    snapshotLoadCount = 0;
    cacheHitCount = 0;
    cacheMissCount = 0;
    offlineLoadCount = 0;
    refreshSuccessCount = 0;
    refreshFailureCount = 0;
    _loadTimeSumMs = 0;
    _loadTimeSamples = 0;
  }
}
