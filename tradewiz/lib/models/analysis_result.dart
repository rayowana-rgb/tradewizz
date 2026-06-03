import 'market.dart';

/// Result of an AI/quantitative analysis for a single symbol.
///
/// Mirrors what the existing Telegram screening bot returns so the migration
/// can map its output straight onto this model.
class AnalysisResult {
  const AnalysisResult({
    required this.symbol,
    required this.market,
    required this.signal,
    required this.score,
    required this.summary,
    required this.highlights,
    required this.generatedAt,
  });

  final String symbol;
  final Market market;

  /// e.g. BUY / HOLD / SELL.
  final String signal;

  /// 0..100 conviction score.
  final double score;

  final String summary;
  final List<String> highlights;
  final DateTime generatedAt;

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    return AnalysisResult(
      symbol: json['symbol'] as String,
      market: Market.values.firstWhere(
        (m) => m.code == (json['market'] as String?),
        orElse: () => Market.idx,
      ),
      signal: json['signal'] as String? ?? 'HOLD',
      score: (json['score'] as num?)?.toDouble() ?? 0,
      summary: json['summary'] as String? ?? '',
      highlights: (json['highlights'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'market': market.code,
        'signal': signal,
        'score': score,
        'summary': summary,
        'highlights': highlights,
        'generated_at': generatedAt.toIso8601String(),
      };
}

/// Weekly prediction returned by /predict_weekly/{symbol}.
class WeeklyPrediction {
  const WeeklyPrediction({
    required this.symbol,
    required this.direction,
    required this.expectedChangePercent,
    required this.confidence,
    required this.rationale,
  });

  final String symbol;

  /// UP / DOWN / FLAT.
  final String direction;
  final double expectedChangePercent;

  /// 0..1 confidence.
  final double confidence;
  final String rationale;

  factory WeeklyPrediction.fromJson(Map<String, dynamic> json) {
    return WeeklyPrediction(
      symbol: json['symbol'] as String,
      direction: json['direction'] as String? ?? 'FLAT',
      expectedChangePercent:
          (json['expected_change_percent'] as num?)?.toDouble() ?? 0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      rationale: json['rationale'] as String? ?? '',
    );
  }
}
