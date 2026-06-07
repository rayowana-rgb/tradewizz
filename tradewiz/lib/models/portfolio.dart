import 'market.dart';

/// Aggregated portfolio summary across connected brokers (GET /v1/portfolio).
class PortfolioSummary {
  const PortfolioSummary({
    this.totalEquity = 0,
    this.cash = 0,
    this.buyingPower = 0,
    this.marketValue = 0,
    this.floatingPnl = 0,
    this.realizedPnl = 0,
  });

  final double totalEquity;
  final double cash;
  final double buyingPower;
  final double marketValue;
  final double floatingPnl;
  final double realizedPnl;

  factory PortfolioSummary.fromJson(Map<String, dynamic> j) => PortfolioSummary(
        totalEquity: (j['total_equity'] as num?)?.toDouble() ?? 0,
        cash: (j['cash'] as num?)?.toDouble() ?? 0,
        buyingPower: (j['buying_power'] as num?)?.toDouble() ?? 0,
        marketValue: (j['market_value'] as num?)?.toDouble() ?? 0,
        floatingPnl: (j['floating_pnl'] as num?)?.toDouble() ?? 0,
        realizedPnl: (j['realized_pnl'] as num?)?.toDouble() ?? 0,
      );
}

/// A single aggregated position with its source broker.
class PortfolioPosition {
  const PortfolioPosition({
    required this.symbol,
    required this.market,
    required this.broker,
    required this.quantity,
    required this.averageCost,
    required this.currentPrice,
    required this.marketValue,
    required this.unrealizedPnl,
  });

  final String symbol;
  final Market market;
  final String broker;
  final double quantity;
  final double averageCost;
  final double currentPrice;
  final double marketValue;
  final double unrealizedPnl;

  factory PortfolioPosition.fromJson(Map<String, dynamic> j) =>
      PortfolioPosition(
        symbol: j['symbol'] as String? ?? '',
        market: Market.values.firstWhere(
          (m) => m.code == (j['market'] as String?),
          orElse: () => Market.hkex,
        ),
        broker: j['broker'] as String? ?? '',
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        averageCost: (j['average_cost'] as num?)?.toDouble() ?? 0,
        currentPrice: (j['current_price'] as num?)?.toDouble() ?? 0,
        marketValue: (j['market_value'] as num?)?.toDouble() ?? 0,
        unrealizedPnl: (j['unrealized_pnl'] as num?)?.toDouble() ?? 0,
      );
}

/// Unified portfolio: summary + positions (+ broker list / errors).
class UnifiedPortfolio {
  const UnifiedPortfolio({
    required this.summary,
    this.positions = const [],
    this.brokers = const [],
  });

  final PortfolioSummary summary;
  final List<PortfolioPosition> positions;
  final List<String> brokers;

  factory UnifiedPortfolio.fromJson(Map<String, dynamic> j) => UnifiedPortfolio(
        summary: PortfolioSummary.fromJson(
            (j['summary'] as Map<String, dynamic>?) ?? const {}),
        positions: (j['positions'] as List<dynamic>? ?? [])
            .map((e) => PortfolioPosition.fromJson(e as Map<String, dynamic>))
            .toList(),
        brokers: (j['brokers'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
      );
}
