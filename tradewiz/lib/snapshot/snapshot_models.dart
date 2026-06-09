import '../models/market.dart';
import '../models/market_index.dart';
import '../models/phase2.dart';
import '../models/phase3.dart';
import '../models/subscription.dart';

/// Snapshot models (Phase F) — thin, parse-on-demand wrappers around the raw
/// JSON documents returned by `/v1/snapshot/*`.
///
/// The whole document is stored verbatim in Hive (Phase G). Each typed getter
/// re-parses a section via the EXISTING model `fromJson`, so the snapshot layer
/// adds no new parsing logic and stays decoupled from model internals. Any
/// missing/null section returns null (the screen then keeps its prior data).

DateTime? _parseTime(Object? v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}

Map<String, dynamic>? _asMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

List<Map<String, dynamic>> _asMapList(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

/// The dashboard snapshot: indices + brief + rotation + radar + daily +
/// multibagger + watchlist AI + notifications, in one document.
class DashboardSnapshot {
  DashboardSnapshot(this.raw, {this.market = Market.us});

  final Map<String, dynamic> raw;
  final Market market;

  DateTime? get generatedAt => _parseTime(raw['generated_at']);

  Map<String, double> get sectionAges {
    final a = raw['section_ages'];
    if (a is Map) {
      return a.map((k, v) =>
          MapEntry(k.toString(), (v is num) ? v.toDouble() : -1.0));
    }
    return const {};
  }

  List<MarketIndex> get indices {
    final m = _asMap(raw['indices']);
    if (m == null) return const [];
    return parseMarketIndices(m);
  }

  MorningBrief? get morningBrief {
    final m = _asMap(raw['morning_brief']);
    return m == null ? null : MorningBrief.fromJson(m);
  }

  GlobalRotation? get rotation {
    final m = _asMap(raw['rotation']);
    return m == null ? null : GlobalRotation.fromJson(m);
  }

  OpportunitiesResult? get radar {
    final m = _asMap(raw['radar']);
    return m == null ? null : OpportunitiesResult.fromJson(m);
  }

  DailyPicks? get dailyPicks {
    final m = _asMap(raw['daily_picks']);
    return m == null ? null : DailyPicks.fromJson(m);
  }

  MultibaggerResult? get multibagger {
    final m = _asMap(raw['multibagger']);
    return m == null ? null : MultibaggerResult.fromJson(m);
  }

  AutoWatchlistSuggestions? get watchlistAi {
    final m = _asMap(raw['watchlist_ai']);
    return m == null ? null : AutoWatchlistSuggestions.fromJson(m);
  }

  NotificationList? get notifications {
    final m = _asMap(raw['notifications']);
    return m == null ? null : NotificationList.fromJson(m);
  }
}

/// The portfolio snapshot: account + positions + health/quality/manager.
class PortfolioSnapshot {
  PortfolioSnapshot(this.raw);

  final Map<String, dynamic> raw;

  DateTime? get generatedAt => _parseTime(raw['generated_at']);

  Map<String, dynamic>? get account => _asMap(raw['account']);
  List<Map<String, dynamic>> get positions => _asMapList(raw['positions']);
  List<Map<String, dynamic>> get portfolioQuality =>
      _asMapList(raw['portfolio_quality']);

  PortfolioHealth? get portfolioHealth {
    final m = _asMap(raw['portfolio_health']);
    return m == null ? null : PortfolioHealth.fromJson(m);
  }

  PortfolioManagerReport? get portfolioManager {
    final m = _asMap(raw['portfolio_manager']);
    return m == null ? null : PortfolioManagerReport.fromJson(m);
  }
}

/// The watchlist snapshot: watchlist AI + rotation + daily picks.
class WatchlistSnapshot {
  WatchlistSnapshot(this.raw, {this.market = Market.us});

  final Map<String, dynamic> raw;
  final Market market;

  DateTime? get generatedAt => _parseTime(raw['generated_at']);

  List<Map<String, dynamic>> get watchlistAi =>
      _asMapList(raw['watchlist_ai']);
  List<Map<String, dynamic>> get dailyPicks => _asMapList(raw['daily_picks']);

  GlobalRotation? get rotation {
    final m = _asMap(raw['rotation']);
    return m == null ? null : GlobalRotation.fromJson(m);
  }
}
