import '../models/market.dart';

/// Stable Hive keys + display TTLs for the snapshot layer (Phase G).
///
/// Snapshots are persisted in the existing Hive cache box under these keys
/// (one full JSON document each), giving the "dashboard_snapshot" /
/// "portfolio_snapshot" / "watchlist_snapshot" storage required by Phase G
/// without standing up a second Hive box infrastructure.
class SnapshotKeys {
  SnapshotKeys._();

  static String dashboard(Market m) => 'dashboard_snapshot_${m.code}';
  static const String portfolio = 'portfolio_snapshot';
  static String watchlist(Market m) => 'watchlist_snapshot_${m.code}';

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
      key == portfolio ||
      key.startsWith('watchlist_snapshot');
}
