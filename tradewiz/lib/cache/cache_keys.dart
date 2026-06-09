import '../models/market.dart';

/// Canonical cache keys + their TTLs.
///
/// Keep keys here so production code and the Cache Inspector agree on names.
class CacheKeys {
  CacheKeys._();

  /// Hive box that stores every cache entry.
  static const String boxName = 'tradewiz_cache';

  // --- keys -----------------------------------------------------------------
  static String morningBrief(Market market) => 'morning_brief_${market.code}';
  static const String globalRotation = 'global_rotation';
  static const String indices = 'indices';
  static String radar(Market market) => 'radar_${market.code}';
  static const String portfolioHealth = 'portfolio_health';
  static const String autoWatchlist = 'auto_watchlist';
  static const String notifications = 'notifications';

  // --- TTLs (per spec) ------------------------------------------------------
  static const Duration ttlMorningBrief = Duration(minutes: 15);
  static const Duration ttlGlobalRotation = Duration(minutes: 15);
  static const Duration ttlIndices = Duration(minutes: 1);
  static const Duration ttlRadar = Duration(minutes: 5);
  static const Duration ttlPortfolioHealth = Duration(minutes: 5);
  static const Duration ttlAutoWatchlist = Duration(minutes: 15);
  static const Duration ttlNotifications = Duration(seconds: 30);

  /// TTL for a given key (prefix match for parameterised keys). Used by the
  /// Cache Inspector to report each entry's policy.
  static Duration ttlFor(String key) {
    if (key.startsWith('morning_brief_')) return ttlMorningBrief;
    if (key == globalRotation) return ttlGlobalRotation;
    if (key == indices) return ttlIndices;
    if (key.startsWith('radar_')) return ttlRadar;
    if (key == portfolioHealth) return ttlPortfolioHealth;
    if (key == autoWatchlist) return ttlAutoWatchlist;
    if (key == notifications) return ttlNotifications;
    return const Duration(minutes: 5); // sensible default
  }

  /// Friendly label for the inspector.
  static String labelFor(String key) {
    if (key.startsWith('morning_brief_')) {
      return 'Morning Brief (${key.substring('morning_brief_'.length)})';
    }
    if (key == globalRotation) return 'Rotation';
    if (key == indices) return 'Indices';
    if (key.startsWith('radar_')) {
      return 'Radar (${key.substring('radar_'.length)})';
    }
    if (key == portfolioHealth) return 'Portfolio Health';
    if (key == autoWatchlist) return 'Auto Watchlist';
    if (key == notifications) return 'Notifications';
    return key;
  }
}
