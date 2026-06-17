// Dashboard Market Overview from `GET /v1/market/overview/{market}`.
//
// All aggregates are nullable: when the backend cannot build the overview it
// returns `available: false` with null fields rather than fabricated values,
// so the UI shows a clear "unavailable" state instead of mock numbers.

double? _toDouble(Object? v) => v == null ? null : (v as num).toDouble();
int? _toInt(Object? v) => v == null ? null : (v as num).toInt();

class MoverRef {
  const MoverRef({
    required this.symbol,
    required this.name,
    required this.price,
    required this.changePercent,
    this.valueTraded = 0,
  });

  final String symbol;
  final String name;
  final double price;
  final double changePercent;
  final double valueTraded;

  factory MoverRef.fromJson(Map<String, dynamic> j) => MoverRef(
        symbol: j['symbol'] as String? ?? '',
        name: j['name'] as String? ?? '',
        price: _toDouble(j['price']) ?? 0,
        changePercent: _toDouble(j['change_percent']) ?? 0,
        valueTraded: _toDouble(j['value_traded']) ?? 0,
      );
}

class ForeignFlow {
  const ForeignFlow({
    required this.available,
    this.netValue,
    this.currency = 'IDR',
  });

  final bool available;
  final double? netValue;
  final String currency;

  factory ForeignFlow.fromJson(Map<String, dynamic> j) => ForeignFlow(
        available: j['available'] as bool? ?? false,
        netValue: _toDouble(j['net_value']),
        currency: j['currency'] as String? ?? 'IDR',
      );
}

class MarketOverview {
  const MarketOverview({
    required this.market,
    required this.available,
    required this.currency,
    this.status,
    this.advances,
    this.declines,
    this.unchanged,
    this.total,
    this.totalValueTraded,
    this.topGainer,
    this.topLoser,
    this.topGainers = const [],
    this.topLosers = const [],
    this.mostActive = const [],
    this.foreignFlow,
    this.updatedAt,
  });

  final String market;
  final bool available;
  final String currency;
  final String? status;
  final int? advances;
  final int? declines;
  final int? unchanged;
  final int? total;
  final double? totalValueTraded;
  final MoverRef? topGainer;
  final MoverRef? topLoser;
  final List<MoverRef> topGainers;
  final List<MoverRef> topLosers;
  final List<MoverRef> mostActive;
  final ForeignFlow? foreignFlow;
  final String? updatedAt;

  bool get hasMovers =>
      topGainers.isNotEmpty || topLosers.isNotEmpty || mostActive.isNotEmpty;

  factory MarketOverview.fromJson(Map<String, dynamic> j) {
    final breadth = (j['breadth'] as Map<String, dynamic>?) ?? const {};
    final gainer = j['top_gainer'] as Map<String, dynamic>?;
    final loser = j['top_loser'] as Map<String, dynamic>?;
    final ff = j['foreign_flow'] as Map<String, dynamic>?;
    List<MoverRef> movers(Object? raw) => (raw as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MoverRef.fromJson)
        .toList(growable: false);
    return MarketOverview(
      market: j['market'] as String? ?? '',
      available: j['available'] as bool? ?? false,
      currency: j['currency'] as String? ?? '',
      status: j['status'] as String?,
      advances: _toInt(breadth['advances']),
      declines: _toInt(breadth['declines']),
      unchanged: _toInt(breadth['unchanged']),
      total: _toInt(breadth['total']),
      totalValueTraded: _toDouble(j['total_value_traded']),
      topGainer: gainer == null ? null : MoverRef.fromJson(gainer),
      topLoser: loser == null ? null : MoverRef.fromJson(loser),
      topGainers: movers(j['top_gainers']),
      topLosers: movers(j['top_losers']),
      mostActive: movers(j['most_active']),
      foreignFlow: ff == null ? null : ForeignFlow.fromJson(ff),
      updatedAt: j['updated_at'] as String?,
    );
  }
}
