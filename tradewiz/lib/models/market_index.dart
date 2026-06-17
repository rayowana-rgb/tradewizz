/// A single market index quote from `GET /v1/market/indices`.
///
/// Numbers are nullable: when the backend cannot reach the data source it
/// returns `available: false` with null price/change rather than fabricated
/// values, so the Dashboard can show a clear "unavailable" warning.
class MarketIndex {
  const MarketIndex({
    required this.symbol,
    required this.market,
    required this.name,
    required this.currency,
    required this.status,
    required this.available,
    this.price,
    this.change,
    this.changePercent,
    this.updatedAt,
    this.sparkline = const [],
    this.prevClose,
  });

  final String symbol;
  final String market;
  final String name;
  final String currency;

  /// 'OPEN' or 'CLOSED'.
  final String status;

  /// False when the backend could not fetch real data for this index.
  final bool available;

  final double? price;
  final double? change;
  final double? changePercent;
  final String? updatedAt;

  /// Recent daily closes (oldest -> newest) for the Home sparkline. Empty when
  /// the backend could not build a trustworthy series.
  final List<double> sparkline;

  /// Previous daily close — the dashed reference line on the chart. Null when
  /// unavailable.
  final double? prevClose;

  bool get isUp => (change ?? 0) >= 0;
  bool get hasData => available && price != null;

  /// True only when there is enough series data to draw a meaningful chart.
  bool get hasSparkline => sparkline.length >= 2;

  static double? _toDouble(Object? v) =>
      v == null ? null : (v as num).toDouble();

  static List<double> _toDoubleList(Object? v) {
    if (v is! List) return const [];
    final out = <double>[];
    for (final e in v) {
      if (e is num) out.add(e.toDouble());
    }
    return out;
  }

  factory MarketIndex.fromJson(Map<String, dynamic> j) => MarketIndex(
        symbol: j['symbol'] as String? ?? '',
        market: j['market'] as String? ?? '',
        name: j['name'] as String? ?? '',
        currency: j['currency'] as String? ?? '',
        status: j['status'] as String? ?? 'CLOSED',
        // Treat a missing `available` as available only when a price exists.
        available: j['available'] as bool? ?? (j['price'] != null),
        price: _toDouble(j['price']),
        change: _toDouble(j['change']),
        changePercent: _toDouble(j['change_percent']),
        updatedAt: j['updated_at'] as String?,
        sparkline: _toDoubleList(j['sparkline']),
        prevClose: _toDouble(j['prev_close']),
      );
}

/// Rule-based Fear/Greed market condition from `GET /v1/market/condition`
/// (Phase E). Derived purely from the index's recent price action; no LLM.
class MarketCondition {
  const MarketCondition({
    required this.condition,
    required this.score,
    required this.reason,
    this.horizons = const [],
  });

  /// One of EXTREME_FEAR / FEAR / NEUTRAL / GREED / EXTREME_GREED / UNKNOWN.
  final String condition;

  /// 0..100 (50 when UNKNOWN).
  final int score;
  final String reason;

  /// Per-timeframe breakdown (daily / weekly / monthly). Empty for older
  /// backends that only return the single headline reading.
  final List<HorizonCondition> horizons;

  /// Human-friendly label, e.g. "Extreme Greed".
  String get label => conditionLabel(condition);

  bool get isKnown => condition != 'UNKNOWN';

  bool get hasHorizons => horizons.isNotEmpty;

  factory MarketCondition.fromJson(Map<String, dynamic> j) => MarketCondition(
        condition: (j['condition'] ?? 'UNKNOWN').toString(),
        score: ((j['condition_score'] ?? 50) as num).toInt(),
        reason: (j['reason'] ?? '').toString(),
        horizons: (j['horizons'] is List)
            ? (j['horizons'] as List)
                .whereType<Map<String, dynamic>>()
                .map(HorizonCondition.fromJson)
                .toList()
            : const [],
      );

  static const MarketCondition unknown =
      MarketCondition(condition: 'UNKNOWN', score: 50, reason: '');
}

/// Map a raw condition code to a friendly label.
String conditionLabel(String condition) => switch (condition) {
      'EXTREME_FEAR' => 'Extreme Fear',
      'FEAR' => 'Fear',
      'NEUTRAL' => 'Neutral',
      'GREED' => 'Greed',
      'EXTREME_GREED' => 'Extreme Greed',
      _ => 'Unknown',
    };

/// A single timeframe's Fear/Greed reading from `horizons[]`.
class HorizonCondition {
  const HorizonCondition({
    required this.horizon,
    required this.condition,
    required this.score,
    required this.reason,
    required this.available,
  });

  /// 'daily' | 'weekly' | 'monthly'.
  final String horizon;
  final String condition;

  /// 0..100; -1 when unavailable (no data for this horizon).
  final int score;
  final String reason;
  final bool available;

  String get label => conditionLabel(condition);

  /// Compact label that fits a narrow 3-up chip, e.g. "Ext. Greed".
  String get shortLabel => switch (condition) {
        'EXTREME_FEAR' => 'Ext. Fear',
        'EXTREME_GREED' => 'Ext. Greed',
        _ => conditionLabel(condition),
      };

  /// Title-cased horizon name, e.g. "Daily".
  String get horizonLabel => switch (horizon) {
        'daily' => 'Daily',
        'weekly' => 'Weekly',
        'monthly' => 'Monthly',
        _ => horizon.isEmpty
            ? horizon
            : horizon[0].toUpperCase() + horizon.substring(1),
      };

  bool get isKnown => available && condition != 'UNKNOWN';

  factory HorizonCondition.fromJson(Map<String, dynamic> j) {
    final raw = j['condition_score'];
    return HorizonCondition(
      horizon: (j['horizon'] ?? '').toString(),
      condition: (j['condition'] ?? 'UNKNOWN').toString(),
      score: raw is num ? raw.toInt() : -1,
      reason: (j['reason'] ?? '').toString(),
      available: j['available'] == null ? raw is num : j['available'] == true,
    );
  }
}

/// Parse the `{ "indices": [...] }` envelope.
List<MarketIndex> parseMarketIndices(Map<String, dynamic> j) {
  final raw = j['indices'];
  if (raw is! List) return const [];
  return raw
      .whereType<Map<String, dynamic>>()
      .map(MarketIndex.fromJson)
      .toList();
}
