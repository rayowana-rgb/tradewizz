import '../models/market.dart';

/// Stable Hive keys + display TTLs for the snapshot layer (Phase G).
///
/// Snapshots are persisted in the existing Hive cache box under these keys
/// (one full JSON document each), giving the "dashboard_snapshot" /
/// "portfolio_snapshot" / "watchlist_snapshot" storage required by Phase G
/// without standing up a second Hive box infrastructure.
class SnapshotKeys {
  SnapshotKeys._();

  /// Scoring/schema version baked into every cache key (Phase I).
  ///
  /// Bump this whenever the scoring engine changes in a way that makes
  /// previously cached snapshots untrustworthy (e.g. the liquidity-safe
  /// scoring fix). Because the version is part of the Hive key, old snapshots
  /// written under a previous version become unreachable and a fresh fetch
  /// repopulates — stale "illiquid 90+" snapshots can never resurface on Home.
  ///
  /// v2 = liquidity-safe scoring (value_traded cap, illiquid never BUY/elite).
  static const String scoringSchemaVersion = 'v2';

  static String dashboard(Market m) =>
      'dashboard_snapshot_${scoringSchemaVersion}_${m.code}';
  static const String portfolio = 'portfolio_snapshot_$scoringSchemaVersion';
  static String watchlist(Market m) =>
      'watchlist_snapshot_${scoringSchemaVersion}_${m.code}';

  /// How long a stored snapshot is treated as fresh before a background
  /// refresh is attempted. (The backend caches with its own, longer TTLs;
  /// these only gate the client's "refresh now" decision.)
  static const Duration dashboardTtl = Duration(minutes: 1);
  static const Duration portfolioTtl = Duration(minutes: 5);
  static const Duration watchlistTtl = Duration(minutes: 15);

  static String label(String key) {
    if (key.startsWith('dashboard_snapshot')) return 'Dashboard';
    if (key == portfolio) return 'Portfolio';
    if (key.startsWith('watchlist_snapshot')) return 'Watchlist';
    return key;
  }

  static const List<String> all = [portfolio];

  /// All snapshot keys currently relevant (per-market dashboards/watchlists are
  /// resolved dynamically from the cache).
  static bool isSnapshotKey(String key) =>
      key.startsWith('dashboard_snapshot') ||
      key.startsWith('portfolio_snapshot') ||
      key.startsWith('watchlist_snapshot');
}
