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
  });

  final String symbol;
  final String name;
  final double score;
  final String signal;
  final double price;
  final double changePercent;

  /// Tags assigned by the screening engine (bullish, scalping, etc.).
  final List<ScreenerCategory> categories;

  bool get isUp => changePercent >= 0;

  bool hasCategory(ScreenerCategory c) => categories.contains(c);

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
  });

  final Market market;
  final List<ScreenerMatch> matches;
  final DateTime generatedAt;

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
    );
  }
}
