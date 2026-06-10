import 'market.dart';
import 'screener_category.dart';

/// A single matched row from a screener run.
class ScreenerMatch {
  const ScreenerMatch({
    required this.symbol,
    required this.name,
    required this.score,
    required this.signal,
    required this.price,
    required this.changePercent,
    this.categories = const [],
    this.baseScore,
    this.categoryBonus = 0,
    this.convictionScore = 0,
    this.finalScore,
    this.exploreTags = const [],
    this.liquidityScore,
    this.participationScore,
    this.valueTradedToday,
    this.avgValueTraded20d,
    this.volumeToday,
    this.avgVolume20d,
    this.volumeRatio20d,
    this.valueTradedRatio20d,
  });

  final String symbol;
  final String name;

  /// Base Score == the existing scoring engine output (technical + ML +
  /// liquidity cap). Unchanged by Phase 9A.
  final double score;
  final String signal;
  final double price;
  final double changePercent;

  /// Tags assigned by the screening engine (bullish, scalping, etc.).
  final List<ScreenerCategory> categories;

  // --- Phase 9A Explore intelligence (backward compatible) ----------------
  /// Mirror of [score]; the Base Score before the Explore overlay. Null on
  /// older servers (fall back to [score]).
  final double? baseScore;

  /// bot9 category bonus (0..25), added on top of the Base Score.
  final int categoryBonus;

  /// Money-flow / trend conviction (0..20), independent of the Base Score.
  final int convictionScore;

  /// Final Explore Score = clamp(base + bonus + conviction, 0..100). Null on
  /// older servers (fall back to [score]).
  final double? finalScore;

  /// Human-readable Explore tags (Bullish, Silent Accumulation, Strong CMF...).
  final List<String> exploreTags;

  // --- Phase 11B liquidity-first participation (backward compatible) -------
  /// Liquidity & participation score (0..100): the dominant scoring factor.
  /// Null on older servers/snapshots that predate Phase 11B.
  final double? liquidityScore;

  /// Mirror of [liquidityScore] for the breakdown label.
  final double? participationScore;

  /// Raw turnover/volume figures backing the liquidity breakdown.
  final double? valueTradedToday;
  final double? avgValueTraded20d;
  final double? volumeToday;
  final double? avgVolume20d;
  final double? volumeRatio20d;
  final double? valueTradedRatio20d;

  /// True when the server sent the Phase 11B liquidity fields.
  bool get hasLiquidityBreakdown => liquidityScore != null;

  bool get isUp => changePercent >= 0;

  bool hasCategory(ScreenerCategory c) => categories.contains(c);

  /// The Base Score to display (mirror falls back to [score]).
  double get effectiveBaseScore => baseScore ?? score;

  /// The Final Explore Score to display/sort by (falls back to [score]).
  double get effectiveFinalScore => finalScore ?? score;

  factory ScreenerMatch.fromJson(Map<String, dynamic> json) {
    return ScreenerMatch(
      symbol: json['symbol'] as String,
      name: json['name'] as String? ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0,
      signal: json['signal'] as String? ?? 'HOLD',
      price: (json['price'] as num?)?.toDouble() ?? 0,
      changePercent: (json['change_percent'] as num?)?.toDouble() ?? 0,
      categories: (json['categories'] as List<dynamic>? ?? [])
          .map((e) => ScreenerCategory.fromWire(e?.toString()))
          .whereType<ScreenerCategory>()
          .toList(),
      baseScore: (json['base_score'] as num?)?.toDouble(),
      categoryBonus: (json['category_bonus'] as num?)?.toInt() ?? 0,
      convictionScore: (json['conviction_score'] as num?)?.toInt() ?? 0,
      finalScore: (json['final_score'] as num?)?.toDouble(),
      exploreTags: (json['explore_tags'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      liquidityScore: (json['liquidity_score'] as num?)?.toDouble(),
      participationScore: (json['participation_score'] as num?)?.toDouble(),
      valueTradedToday: (json['value_traded_today'] as num?)?.toDouble(),
      avgValueTraded20d: (json['avg_value_traded_20d'] as num?)?.toDouble(),
      volumeToday: (json['volume_today'] as num?)?.toDouble(),
      avgVolume20d: (json['avg_volume_20d'] as num?)?.toDouble(),
      volumeRatio20d: (json['volume_ratio_20d'] as num?)?.toDouble(),
      valueTradedRatio20d:
          (json['value_traded_ratio_20d'] as num?)?.toDouble(),
    );
  }
}

/// Result of a screener run for a market (/screen/{market}).
class ScreenerResult {
  const ScreenerResult({
    required this.market,
    required this.matches,
    required this.generatedAt,
    this.totalCount,
    this.returnedCount,
    this.limit,
    this.minScore,
    this.categories = const [],
    this.cached = false,
    this.marketStatus,
    this.marketDate,
    this.nextRefreshRule,
    this.warning,
  });

  final Market market;
  final List<ScreenerMatch> matches;
  final DateTime generatedAt;

  // --- Market-close caching metadata (backward compatible) ----------------
  /// True when these results were served from a saved market-close snapshot.
  final bool cached;

  /// "OPEN" or "CLOSED" (market-local) at the time of the response. Null on
  /// older servers that don't report it.
  final String? marketStatus;

  /// Market-local date (YYYY-MM-DD) of the cached snapshot, if any.
  final String? marketDate;

  /// Human-readable refresh policy, e.g. "Will refresh after next market close".
  final String? nextRefreshRule;

  /// Optional warning (e.g. force_refresh refused while the market is open).
  final String? warning;

  /// True when the market is currently open (per the server's report).
  bool get isMarketOpen => marketStatus == 'OPEN';

  /// Matches after filtering, BEFORE the limit. Null if the server is old and
  /// did not send pagination metadata (backward compatible).
  final int? totalCount;

  /// Matches actually returned. Null if not provided by the server.
  final int? returnedCount;

  /// Limit the server applied. Null if not provided.
  final int? limit;

  /// Min score the server applied. Null if not provided.
  final double? minScore;

  /// Category wire names the server filtered by (may be empty).
  final List<String> categories;

  /// True when the server reports more matches than were returned.
  bool get hasMore =>
      totalCount != null &&
      returnedCount != null &&
      totalCount! > returnedCount!;

  /// Count actually shown (falls back to matches length).
  int get shownCount => returnedCount ?? matches.length;

  factory ScreenerResult.fromJson(Map<String, dynamic> json) {
    final matches = (json['matches'] as List<dynamic>? ?? [])
        .map((e) => ScreenerMatch.fromJson(e as Map<String, dynamic>))
        .toList();
    return ScreenerResult(
      market: Market.values.firstWhere(
        (m) => m.code == (json['market'] as String?),
        orElse: () => Market.idx,
      ),
      matches: matches,
      generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? '') ??
          DateTime.now(),
      // Backward compatible: these are null/empty when the server omits them.
      totalCount: (json['total_count'] as num?)?.toInt(),
      returnedCount: (json['returned_count'] as num?)?.toInt(),
      limit: (json['limit'] as num?)?.toInt(),
      minScore: (json['min_score'] as num?)?.toDouble(),
      categories: (json['categories'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      cached: json['cached'] as bool? ?? false,
      marketStatus: json['market_status'] as String?,
      marketDate: json['market_date'] as String?,
      nextRefreshRule: json['next_refresh_rule'] as String?,
      warning: json['warning'] as String?,
    );
  }
}
