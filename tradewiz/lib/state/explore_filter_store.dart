import '../models/market.dart';
import '../models/screener_category.dart';

/// Instrument-type filter for the Explore/Screener view.
enum InstrumentTypeFilter {
  all,
  stock,
  etf;

  String get label => switch (this) {
        InstrumentTypeFilter.all => 'All',
        InstrumentTypeFilter.stock => 'Stocks',
        InstrumentTypeFilter.etf => 'ETFs',
      };
}

/// In-memory store for the Explore/Screener filter state.
///
/// The bottom navigation rebuilds (and, depending on the shell, disposes) the
/// [ScreenerPage] State when the user switches tabs. Local State on the page is
/// therefore not durable across Home -> Explore round-trips. This store keeps
/// the user's filter selections alive for the lifetime of the app process so
/// returning to Explore restores exactly what was selected.
///
/// Scope: in-memory only. No backend, no database, no SharedPreferences. It can
/// be upgraded to persist to SharedPreferences later without changing callers.
/// It deliberately holds ONLY view/filter state — nothing about scoring,
/// ranking, final_score, or the screener results themselves.
class ExploreFilterStore {
  ExploreFilterStore._();

  /// Process-lifetime singleton. The whole point is that it survives widget
  /// rebuilds and tab switches, so it must not be recreated per page.
  static final ExploreFilterStore instance = ExploreFilterStore._();

  /// Selected market (mirrors the shell's market selector).
  Market? market;

  /// Selected category filter (single-select, matching the existing model).
  ScreenerCategory? categoryFilter;

  /// Instrument-type filter (All / Stocks / ETFs). Defaults to All.
  InstrumentTypeFilter instrumentType = InstrumentTypeFilter.all;

  /// Minimum score (0 == no minimum).
  double minScore = 0;

  /// Signal filter: 'BUY' | 'HOLD' | 'SELL' | null.
  String? signalFilter;

  /// Hide illiquid / AVOID rows.
  bool hideIlliquid = false;

  /// Free-text search query.
  String query = '';

  /// True once the user has touched any filter, so a fresh page knows whether
  /// to restore (vs. use its constructor defaults on very first launch).
  bool _hydrated = false;
  bool get hydrated => _hydrated;

  /// Persist the current filter selection. Called by the page whenever any
  /// filter changes.
  void save({
    Market? market,
    ScreenerCategory? categoryFilter,
    required double minScore,
    String? signalFilter,
    required bool hideIlliquid,
    required String query,
    InstrumentTypeFilter instrumentType = InstrumentTypeFilter.all,
  }) {
    this.market = market;
    this.categoryFilter = categoryFilter;
    this.minScore = minScore;
    this.signalFilter = signalFilter;
    this.hideIlliquid = hideIlliquid;
    this.query = query;
    this.instrumentType = instrumentType;
    _hydrated = true;
  }

  /// Reset everything to defaults (used by tests and an explicit "clear all").
  void reset() {
    market = null;
    categoryFilter = null;
    minScore = 0;
    signalFilter = null;
    hideIlliquid = false;
    query = '';
    instrumentType = InstrumentTypeFilter.all;
    _hydrated = false;
  }
}
