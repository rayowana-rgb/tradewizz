import 'dart:async';

import '../models/market.dart';
import '../models/market_index.dart';
import '../models/phase2.dart';
import '../models/phase3.dart';
import '../models/subscription.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import 'cache_entry.dart';
import 'cache_keys.dart';
import 'cache_service.dart';

/// Stale-while-revalidate (SWR) wrapper around [StockRepository].
///
/// Each SWR method:
///   1. Emits the cached value immediately (if present) so the UI renders fast.
///   2. Fetches fresh data in the background.
///   3. On success, writes the cache and emits the fresh value (only when it
///      actually differs from what was already shown).
///   4. On failure, keeps the cached value and emits it flagged `offline` so
///      the UI can show an offline banner instead of a blank screen.
///
/// Cached payloads are the raw API JSON (Hive-friendly); they are re-parsed
/// with each model's `fromJson` on read. This keeps the layer additive and
/// leaves API formats, models, and the live data path unchanged.
class CachedRepository {
  CachedRepository(this._repo, {CacheService? cache})
      : _cache = cache ?? CacheService.instance;

  final StockRepository _repo;
  final CacheService _cache;

  CacheService get cache => _cache;
  StockRepository get repo => _repo;

  // --- generic SWR engine ---------------------------------------------------

  /// Stream up to two values: the cached one (if any) then the fresh one.
  ///
  /// [parse] turns a cached/raw JSON payload into the typed model.
  /// [fetchRaw] performs the network call and returns the raw JSON to cache.
  Stream<Cached<T>> _swr<T>({
    required String key,
    required Duration ttl,
    required Future<Object> Function() fetchRaw,
    required T Function(Object raw) parse,
  }) async* {
    // 1. cache-first
    final entry = _cache.readEntry(key);
    Cached<T>? shown;
    if (entry != null) {
      try {
        shown = Cached<T>(
          value: parse(entry.data as Object),
          isCached: true,
          lastUpdated: entry.cachedAt,
          stale: entry.stale,
        );
        yield shown;
      } catch (_) {
        shown = null; // corrupt payload — ignore, fall through to network
      }
    }

    // 2. background refresh
    try {
      final raw = await fetchRaw();
      await _cache.write(key, raw, ttl: ttl);
      final fresh = Cached<T>(
        value: parse(raw),
        isCached: false,
        lastUpdated: DateTime.now(),
        stale: false,
      );
      // 3. only emit if it changes what's on screen.
      if (shown == null || !_sameRaw(entry?.data, raw)) {
        yield fresh;
      }
    } catch (e) {
      // 4. network failed. If we already showed cache, surface offline so the
      // UI can banner it; otherwise rethrow so the caller shows an error.
      if (shown != null) {
        yield shown.copyWith(offline: true);
      } else if (e is ApiException) {
        rethrow;
      } else {
        throw ApiException('Could not load data.');
      }
    }
  }

  /// Future variant: returns the freshest available value, preferring network
  /// but falling back to (possibly stale) cache when offline. Never throws when
  /// any cache exists.
  Future<Cached<T>> _swrFuture<T>({
    required String key,
    required Duration ttl,
    required Future<Object> Function() fetchRaw,
    required T Function(Object raw) parse,
  }) async {
    final entry = _cache.readEntry(key);
    try {
      final raw = await fetchRaw();
      await _cache.write(key, raw, ttl: ttl);
      return Cached<T>(
        value: parse(raw),
        isCached: false,
        lastUpdated: DateTime.now(),
        stale: false,
      );
    } catch (e) {
      if (entry != null) {
        return Cached<T>(
          value: parse(entry.data as Object),
          isCached: true,
          lastUpdated: entry.cachedAt,
          stale: entry.stale,
          offline: true,
        );
      }
      rethrow;
    }
  }

  bool _sameRaw(Object? a, Object? b) => a.toString() == b.toString();

  /// Read whatever is cached for [key] without any network call (offline-mode
  /// helper). Returns null when nothing is cached.
  Cached<T>? peek<T>(String key, T Function(Object raw) parse) {
    final entry = _cache.readEntry(key);
    if (entry == null) return null;
    try {
      return Cached<T>(
        value: parse(entry.data as Object),
        isCached: true,
        lastUpdated: entry.cachedAt,
        stale: entry.stale,
        offline: true,
      );
    } catch (_) {
      return null;
    }
  }

  // --- Morning Brief (Phase B) ---------------------------------------------
  Stream<Cached<MorningBrief>> morningBriefSwr(String token, Market market) =>
      _swr<MorningBrief>(
        key: CacheKeys.morningBrief(market),
        ttl: CacheKeys.ttlMorningBrief,
        fetchRaw: () => _repo.rawMorningBrief(token, market),
        parse: (raw) => MorningBrief.fromJson(_asMap(raw)),
      );

  Future<Cached<MorningBrief>> morningBrief(String token, Market market) =>
      _swrFuture<MorningBrief>(
        key: CacheKeys.morningBrief(market),
        ttl: CacheKeys.ttlMorningBrief,
        fetchRaw: () => _repo.rawMorningBrief(token, market),
        parse: (raw) => MorningBrief.fromJson(_asMap(raw)),
      );

  // --- Global Rotation (Phase C) -------------------------------------------
  Stream<Cached<GlobalRotation>> globalRotationSwr(String token) =>
      _swr<GlobalRotation>(
        key: CacheKeys.globalRotation,
        ttl: CacheKeys.ttlGlobalRotation,
        fetchRaw: () => _repo.rawGlobalRotation(token),
        parse: (raw) => GlobalRotation.fromJson(_asMap(raw)),
      );

  Future<Cached<GlobalRotation>> globalRotation(String token) =>
      _swrFuture<GlobalRotation>(
        key: CacheKeys.globalRotation,
        ttl: CacheKeys.ttlGlobalRotation,
        fetchRaw: () => _repo.rawGlobalRotation(token),
        parse: (raw) => GlobalRotation.fromJson(_asMap(raw)),
      );

  // --- Indices (Phase D) ----------------------------------------------------
  // Never replace valid data with empty data: if a refresh yields an empty
  // list we keep the previously cached non-empty value.
  Stream<Cached<List<MarketIndex>>> indicesSwr() => _swr<List<MarketIndex>>(
        key: CacheKeys.indices,
        ttl: CacheKeys.ttlIndices,
        fetchRaw: () async {
          final raw = await _repo.rawMarketIndices();
          // Guard: don't overwrite good cache with an empty result.
          final fresh = parseMarketIndices(raw);
          if (fresh.isEmpty) {
            final cached = _cache.read<Object?>(CacheKeys.indices);
            if (cached != null && parseMarketIndices(_asMap(cached)).isNotEmpty) {
              return cached; // keep previous values
            }
          }
          return raw;
        },
        parse: (raw) => parseMarketIndices(_asMap(raw)),
      );

  Future<Cached<List<MarketIndex>>> indices() => _swrFuture<List<MarketIndex>>(
        key: CacheKeys.indices,
        ttl: CacheKeys.ttlIndices,
        fetchRaw: () => _repo.rawMarketIndices(),
        parse: (raw) => parseMarketIndices(_asMap(raw)),
      );

  // --- Radar (Phase E) ------------------------------------------------------
  // Stores opportunities, daily picks, and multibagger candidates together
  // under radar_<market> so the dashboard loads them from one cache entry.
  Stream<Cached<RadarBundle>> radarSwr(String token, Market market) =>
      _swr<RadarBundle>(
        key: CacheKeys.radar(market),
        ttl: CacheKeys.ttlRadar,
        fetchRaw: () async {
          final opps = await _repo.rawRadarOpportunities(token);
          final daily = await _repo.rawRadarDaily(token);
          Map<String, dynamic> mb;
          try {
            mb = await _repo.rawRadarMultibagger(token);
          } catch (_) {
            mb = const {}; // multibagger is Elite-gated; tolerate absence
          }
          return {'opportunities': opps, 'daily': daily, 'multibagger': mb};
        },
        parse: (raw) => RadarBundle.fromJson(_asMap(raw)),
      );

  Future<Cached<RadarBundle>> radar(String token, Market market) =>
      _swrFuture<RadarBundle>(
        key: CacheKeys.radar(market),
        ttl: CacheKeys.ttlRadar,
        fetchRaw: () async {
          final opps = await _repo.rawRadarOpportunities(token);
          final daily = await _repo.rawRadarDaily(token);
          Map<String, dynamic> mb;
          try {
            mb = await _repo.rawRadarMultibagger(token);
          } catch (_) {
            mb = const {};
          }
          return {'opportunities': opps, 'daily': daily, 'multibagger': mb};
        },
        parse: (raw) => RadarBundle.fromJson(_asMap(raw)),
      );

  // --- Portfolio Health (Phase F) ------------------------------------------
  Stream<Cached<PortfolioHealth>> portfolioHealthSwr(String token) =>
      _swr<PortfolioHealth>(
        key: CacheKeys.portfolioHealth,
        ttl: CacheKeys.ttlPortfolioHealth,
        fetchRaw: () => _repo.rawPortfolioHealth(token),
        parse: (raw) => PortfolioHealth.fromJson(_asMap(raw)),
      );

  Future<Cached<PortfolioHealth>> portfolioHealth(String token) =>
      _swrFuture<PortfolioHealth>(
        key: CacheKeys.portfolioHealth,
        ttl: CacheKeys.ttlPortfolioHealth,
        fetchRaw: () => _repo.rawPortfolioHealth(token),
        parse: (raw) => PortfolioHealth.fromJson(_asMap(raw)),
      );

  // --- Auto Watchlist (Phase G) --------------------------------------------
  Stream<Cached<AutoWatchlistSuggestions>> autoWatchlistSwr(
    String token, {
    List<String> existing = const [],
  }) =>
      _swr<AutoWatchlistSuggestions>(
        key: CacheKeys.autoWatchlist,
        ttl: CacheKeys.ttlAutoWatchlist,
        fetchRaw: () =>
            _repo.rawAutoWatchlistSuggestions(token, existing: existing),
        parse: (raw) => AutoWatchlistSuggestions.fromJson(_asMap(raw)),
      );

  Future<Cached<AutoWatchlistSuggestions>> autoWatchlist(
    String token, {
    List<String> existing = const [],
  }) =>
      _swrFuture<AutoWatchlistSuggestions>(
        key: CacheKeys.autoWatchlist,
        ttl: CacheKeys.ttlAutoWatchlist,
        fetchRaw: () =>
            _repo.rawAutoWatchlistSuggestions(token, existing: existing),
        parse: (raw) => AutoWatchlistSuggestions.fromJson(_asMap(raw)),
      );

  // --- Notifications (Phase H) ---------------------------------------------
  Stream<Cached<NotificationList>> notificationsSwr(String token) =>
      _swr<NotificationList>(
        key: CacheKeys.notifications,
        ttl: CacheKeys.ttlNotifications,
        fetchRaw: () => _repo.rawNotifications(token),
        parse: (raw) => NotificationList.fromJson(_asMap(raw)),
      );

  Future<Cached<NotificationList>> notifications(String token) =>
      _swrFuture<NotificationList>(
        key: CacheKeys.notifications,
        ttl: CacheKeys.ttlNotifications,
        fetchRaw: () => _repo.rawNotifications(token),
        parse: (raw) => NotificationList.fromJson(_asMap(raw)),
      );

  // --- Preload (Phase K) ----------------------------------------------------
  /// Warm Morning Brief + Rotation + Indices in parallel so the next launch is
  /// near-instant. Failures are swallowed (best-effort warming).
  Future<void> preloadDashboard(String token, Market market) async {
    await Future.wait<void>([
      morningBrief(token, market).then((_) {}).catchError((_) {}),
      globalRotation(token).then((_) {}).catchError((_) {}),
      indices().then((_) {}).catchError((_) {}),
    ]);
  }

  Map<String, dynamic> _asMap(Object raw) =>
      (raw as Map).cast<String, dynamic>();
}

/// Bundles the three radar payloads stored under one cache key (Phase E).
class RadarBundle {
  RadarBundle({
    required this.opportunities,
    required this.daily,
    this.multibagger,
  });

  final OpportunitiesResult opportunities;
  final DailyPicks daily;
  final MultibaggerResult? multibagger;

  factory RadarBundle.fromJson(Map<String, dynamic> j) {
    final mbRaw = j['multibagger'];
    return RadarBundle(
      opportunities: OpportunitiesResult.fromJson(
          (j['opportunities'] as Map?)?.cast<String, dynamic>() ?? const {}),
      daily: DailyPicks.fromJson(
          (j['daily'] as Map?)?.cast<String, dynamic>() ?? const {}),
      multibagger: (mbRaw is Map && mbRaw.isNotEmpty)
          ? MultibaggerResult.fromJson(mbRaw.cast<String, dynamic>())
          : null,
    );
  }
}
