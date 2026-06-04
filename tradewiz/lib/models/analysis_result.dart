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
    this.recommendation,
    this.buyReasons = const [],
    this.supportResistance,
    this.trailingStopPercent,
    this.trailingStopPrice,
    this.profitProbability,
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

  // --- Phase 3 (optional; null when the server omits them) ---

  /// Human-readable BUY/SELL/HOLD verdict.
  final String? recommendation;

  /// Confirmation reasons (OBV/CMF/A-D/VWAP/MACD/RSI).
  final List<String> buyReasons;

  /// Support/resistance levels.
  final SupportResistance? supportResistance;

  /// ADX-banded trailing stop.
  final double? trailingStopPercent;
  final double? trailingStopPrice;

  /// 0..1 probability the signal is profitable (RandomForest).
  final double? profitProbability;

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    final sr = json['support_resistance'];
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
      recommendation: json['recommendation'] as String?,
      buyReasons: (json['buy_reasons'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      supportResistance:
          sr is Map<String, dynamic> ? SupportResistance.fromJson(sr) : null,
      trailingStopPercent: (json['trailing_stop_percent'] as num?)?.toDouble(),
      trailingStopPrice: (json['trailing_stop_price'] as num?)?.toDouble(),
      profitProbability: (json['profit_probability'] as num?)?.toDouble(),
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

/// Support/resistance levels (rolling min/max), part of [AnalysisResult].
class SupportResistance {
  const SupportResistance({
    this.immediateSupport,
    this.immediateResistance,
    this.majorSupport,
    this.majorResistance,
  });

  final double? immediateSupport;
  final double? immediateResistance;
  final double? majorSupport;
  final double? majorResistance;

  factory SupportResistance.fromJson(Map<String, dynamic> json) {
    double? d(String k) => (json[k] as num?)?.toDouble();
    return SupportResistance(
      immediateSupport: d('immediate_support'),
      immediateResistance: d('immediate_resistance'),
      majorSupport: d('major_support'),
      majorResistance: d('major_resistance'),
    );
  }
}

/// Backtest stats returned by /backtest/{symbol}.
class BacktestResult {
  const BacktestResult({
    required this.symbol,
    required this.market,
    required this.signalType,
    required this.forwardDays,
    required this.totalSignals,
    required this.totalWins,
    required this.totalLosses,
    required this.winRate,
    required this.averageReturn,
    required this.profitFactor,
    required this.maxDrawdown,
  });

  final String symbol;
  final Market market;

  /// momentum / scalping / accumulation.
  final String signalType;
  final int forwardDays;
  final int totalSignals;
  final int totalWins;
  final int totalLosses;

  /// 0..1 fraction of profitable signals.
  final double winRate;

  /// Mean forward return (fraction, e.g. 0.012 == +1.2%).
  final double averageReturn;

  /// gross win / |gross loss| (finite-capped server-side).
  final double profitFactor;

  /// Worst single-signal return (fraction, <= 0).
  final double maxDrawdown;

  bool get hasSignals => totalSignals > 0;

  factory BacktestResult.fromJson(Map<String, dynamic> json) {
    return BacktestResult(
      symbol: json['symbol'] as String? ?? '',
      market: Market.values.firstWhere(
        (m) => m.code == (json['market'] as String?),
        orElse: () => Market.idx,
      ),
      signalType: json['signal_type'] as String? ?? 'momentum',
      forwardDays: (json['forward_days'] as num?)?.toInt() ?? 2,
      totalSignals: (json['total_signals'] as num?)?.toInt() ?? 0,
      totalWins: (json['total_wins'] as num?)?.toInt() ?? 0,
      totalLosses: (json['total_losses'] as num?)?.toInt() ?? 0,
      winRate: (json['win_rate'] as num?)?.toDouble() ?? 0,
      averageReturn: (json['average_return'] as num?)?.toDouble() ?? 0,
      profitFactor: (json['profit_factor'] as num?)?.toDouble() ?? 0,
      maxDrawdown: (json['max_drawdown'] as num?)?.toDouble() ?? 0,
    );
  }
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
