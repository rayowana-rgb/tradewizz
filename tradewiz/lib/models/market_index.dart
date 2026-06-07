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

  bool get isUp => (change ?? 0) >= 0;
  bool get hasData => available && price != null;

  static double? _toDouble(Object? v) =>
      v == null ? null : (v as num).toDouble();

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
      );
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
