import 'market.dart';

/// A single matched row from a screener run.
class ScreenerMatch {
  const ScreenerMatch({
    required this.symbol,
    required this.name,
    required this.score,
    required this.signal,
    required this.price,
    required this.changePercent,
  });

  final String symbol;
  final String name;
  final double score;
  final String signal;
  final double price;
  final double changePercent;

  bool get isUp => changePercent >= 0;

  factory ScreenerMatch.fromJson(Map<String, dynamic> json) {
    return ScreenerMatch(
      symbol: json['symbol'] as String,
      name: json['name'] as String? ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0,
      signal: json['signal'] as String? ?? 'HOLD',
      price: (json['price'] as num?)?.toDouble() ?? 0,
      changePercent: (json['change_percent'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Result of a screener run for a market (/screen/{market}).
class ScreenerResult {
  const ScreenerResult({
    required this.market,
    required this.matches,
    required this.generatedAt,
  });

  final Market market;
  final List<ScreenerMatch> matches;
  final DateTime generatedAt;

  factory ScreenerResult.fromJson(Map<String, dynamic> json) {
    return ScreenerResult(
      market: Market.values.firstWhere(
        (m) => m.code == (json['market'] as String?),
        orElse: () => Market.idx,
      ),
      matches: (json['matches'] as List<dynamic>? ?? [])
          .map((e) => ScreenerMatch.fromJson(e as Map<String, dynamic>))
          .toList(),
      generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
