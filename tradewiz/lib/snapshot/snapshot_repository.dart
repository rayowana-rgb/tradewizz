import 'dart:async';

import '../cache/cache_entry.dart';
import '../cache/cache_service.dart';
import '../models/market.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import 'snapshot_keys.dart';
import 'snapshot_metrics.dart';
import 'snapshot_models.dart';

/// Offline-first snapshot repository (Phases F/G/H/J/K/N).
///
/// One request per surface. The full JSON document is persisted in Hive (via
/// [CacheService]) under a stable key (Phase G). Reads follow the startup flow
/// (Phase H): serve the Hive snapshot immediately, refresh in the background,
/// update Hive + UI on success, keep the previous snapshot on failure.
///
/// Reliability (Phase N): a refresh that yields null / an empty document never
/// overwrites a valid stored snapshot.
class SnapshotRepository {
  SnapshotRepository(
    this._repo, {
    CacheService? cache,
    SnapshotMetrics? metrics,
  })  : _cache = cache ?? CacheService.instance,
        metrics = metrics ?? SnapshotMetrics();

  final StockRepository _repo;
  final CacheService _cache;

  /// Lightweight analytics counters (Phase M).
  final SnapshotMetrics metrics;

  // --- peek (Phase H step 1 / Phase J offline) ----------------------------

  /// The stored dashboard snapshot, or null if none cached. Never hits network.
  DashboardSnapshot? peekDashboard(Market market) {
    final raw = _cache.read<Map>(SnapshotKeys.dashboard(market));
    if (raw == null) return null;
    metrics.cacheHit();
    return DashboardSnapshot(Map<String, dynamic>.from(raw), market: market);
  }

  PortfolioSnapshot? peekPortfolio() {
    final raw = _cache.read<Map>(SnapshotKeys.portfolio);
    if (raw == null) return null;
    metrics.cacheHit();
    return PortfolioSnapshot(Map<String, dynamic>.from(raw));
  }

  WatchlistSnapshot? peekWatchlist(Market market) {
    final raw = _cache.read<Map>(SnapshotKeys.watchlist(market));
    if (raw == null) return null;
    metrics.cacheHit();
    return WatchlistSnapshot(Map<String, dynamic>.from(raw), market: market);
  }

  // --- SWR streams (Phase H + I) ------------------------------------------
  // Emit the cached snapshot first (if any), then the freshly fetched one.

  Stream<Cached<DashboardSnapshot>> dashboardSwr(
    String token,
    Market market, {
    bool force = false,
  }) =>
      _swr<DashboardSnapshot>(
        key: SnapshotKeys.dashboard(market),
        ttl: SnapshotKeys.dashboardTtl,
        parse: (m) => DashboardSnapshot(m, market: market),
        fetch: () => _repo.rawDashboardSnapshot(token, market: market,
            force: force),
        force: force,
      );

  Stream<Cached<PortfolioSnapshot>> portfolioSwr(
    String token, {
    bool force = false,
  }) =>
      _swr<PortfolioSnapshot>(
        key: SnapshotKeys.portfolio,
        ttl: SnapshotKeys.portfolioTtl,
        parse: (m) => PortfolioSnapshot(m),
        fetch: () => _repo.rawPortfolioSnapshot(token, force: force),
        force: force,
      );

  Stream<Cached<WatchlistSnapshot>> watchlistSwr(
    String token,
    Market market, {
    List<String> existing = const [],
    bool force = false,
  }) =>
      _swr<WatchlistSnapshot>(
        key: SnapshotKeys.watchlist(market),
        ttl: SnapshotKeys.watchlistTtl,
        parse: (m) => WatchlistSnapshot(m, market: market),
        fetch: () => _repo.rawWatchlistSnapshot(token, market: market,
            existing: existing, force: force),
        force: force,
      );

  // --- one-shot futures ---------------------------------------------------

  Future<Cached<DashboardSnapshot>> fetchDashboardSnapshot(
    String token,
    Market market, {
    bool force = false,
  }) =>
      dashboardSwr(token, market, force: force).last;

  Future<Cached<PortfolioSnapshot>> fetchPortfolioSnapshot(
    String token, {
    bool force = false,
  }) =>
      portfolioSwr(token, force: force).last;

  Future<Cached<WatchlistSnapshot>> fetchWatchlistSnapshot(
    String token,
    Market market, {
    List<String> existing = const [],
    bool force = false,
  }) =>
      watchlistSwr(token, market, existing: existing, force: force).last;

  // --- preload (used at app open) -----------------------------------------

  /// Warm the dashboard snapshot in the background (best effort).
  Future<void> preload(String token, Market market) async {
    try {
      await fetchDashboardSnapshot(token, market);
    } catch (_) {
      // best effort; cached/empty UI handles the rest.
    }
  }

  // --- core SWR engine ----------------------------------------------------

  Stream<Cached<T>> _swr<T>({
    required String key,
    required Duration ttl,
    required T Function(Map<String, dynamic>) parse,
    required Future<Map<String, dynamic>> Function() fetch,
    required bool force,
  }) async* {
    final sw = Stopwatch()..start();
    final entry = _cache.readEntry(key);

    Map<String, dynamic>? cachedRaw;
    if (entry != null && entry.data is Map) {
      cachedRaw = Map<String, dynamic>.from(entry.data as Map);
      metrics.cacheHit();
      yield Cached<T>(
        value: parse(cachedRaw),
        isCached: true,
        lastUpdated: entry.cachedAt,
        stale: entry.stale,
      );
    } else {
      metrics.cacheMiss();
    }

    // Skip the network refresh only when we have a FRESH cache and no force.
    final fresh = entry != null && !entry.stale;
    if (fresh && !force && cachedRaw != null) {
      return;
    }

    try {
      final raw = await fetch();
      sw.stop();
      metrics.refreshSuccess(sw.elapsedMilliseconds);
      if (_isEmpty(raw)) {
        // Phase N: never overwrite a valid snapshot with an empty document.
        return;
      }
      await _cache.write(key, raw, ttl: ttl);
      // Only emit fresh if it differs from what we already showed.
      if (cachedRaw == null || !_mapEquals(cachedRaw, raw)) {
        yield Cached<T>(
          value: parse(raw),
          isCached: false,
          lastUpdated: DateTime.now(),
        );
      }
    } on ApiException {
      sw.stop();
      metrics.refreshFailure();
      // Offline / backend error: keep + surface the cached snapshot. Never a
      // "Backend Error" while a snapshot exists (Phase H/J).
      if (cachedRaw != null) {
        metrics.offlineLoad();
        yield Cached<T>(
          value: parse(cachedRaw),
          isCached: true,
          lastUpdated: entry!.cachedAt,
          stale: true,
          offline: true,
        );
        return;
      }
      rethrow; // nothing cached -> caller shows "unavailable", never blank.
    } catch (_) {
      sw.stop();
      metrics.refreshFailure();
      if (cachedRaw != null) {
        metrics.offlineLoad();
        return;
      }
      rethrow;
    }
  }

  static bool _isEmpty(Object? raw) {
    if (raw == null) return true;
    if (raw is Map) return raw.isEmpty;
    if (raw is List) return raw.isEmpty;
    return false;
  }

  static bool _mapEquals(Map a, Map b) => a.toString() == b.toString();
}
