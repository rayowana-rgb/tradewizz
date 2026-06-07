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

/// Portfolio performance analytics (GET /v1/portfolio/performance).
class EquityPoint {
  const EquityPoint({required this.timestamp, required this.totalEquity});
  final String timestamp;
  final double totalEquity;
  factory EquityPoint.fromJson(Map<String, dynamic> j) => EquityPoint(
        timestamp: j['timestamp'] as String? ?? '',
        totalEquity: (j['total_equity'] as num?)?.toDouble() ?? 0,
      );
}

class BrokerBreakdown {
  const BrokerBreakdown({
    required this.broker,
    required this.equity,
    required this.cash,
    required this.marketValue,
    required this.floatingPnl,
  });
  final String broker;
  final double equity;
  final double cash;
  final double marketValue;
  final double floatingPnl;
  factory BrokerBreakdown.fromJson(Map<String, dynamic> j) => BrokerBreakdown(
        broker: j['broker'] as String? ?? '',
        equity: (j['equity'] as num?)?.toDouble() ?? 0,
        cash: (j['cash'] as num?)?.toDouble() ?? 0,
        marketValue: (j['market_value'] as num?)?.toDouble() ?? 0,
        floatingPnl: (j['floating_pnl'] as num?)?.toDouble() ?? 0,
      );
}

class AssetBreakdown {
  const AssetBreakdown({
    required this.asset,
    required this.marketValue,
    required this.floatingPnl,
  });
  final String asset;
  final double marketValue;
  final double floatingPnl;
  factory AssetBreakdown.fromJson(Map<String, dynamic> j) => AssetBreakdown(
        asset: j['asset'] as String? ?? '',
        marketValue: (j['market_value'] as num?)?.toDouble() ?? 0,
        floatingPnl: (j['floating_pnl'] as num?)?.toDouble() ?? 0,
      );
}

class PositionPnL {
  const PositionPnL({
    required this.symbol,
    required this.broker,
    required this.unrealizedPnl,
    required this.unrealizedPnlPercent,
  });
  final String symbol;
  final String broker;
  final double unrealizedPnl;
  final double unrealizedPnlPercent;
  factory PositionPnL.fromJson(Map<String, dynamic> j) => PositionPnL(
        symbol: j['symbol'] as String? ?? '',
        broker: j['broker'] as String? ?? '',
        unrealizedPnl: (j['unrealized_pnl'] as num?)?.toDouble() ?? 0,
        unrealizedPnlPercent:
            (j['unrealized_pnl_percent'] as num?)?.toDouble() ?? 0,
      );
}

class PortfolioPerformance {
  const PortfolioPerformance({
    this.totalEquity = 0,
    this.cash = 0,
    this.marketValue = 0,
    this.floatingPnl = 0,
    this.realizedPnl = 0,
    this.totalPnl = 0,
    this.dailyPnl = 0,
    this.dailyPnlPercent = 0,
    this.equityCurve = const [],
    this.brokerBreakdown = const [],
    this.assetBreakdown = const [],
    this.topWinners = const [],
    this.topLosers = const [],
    this.notes = const [],
  });

  final double totalEquity;
  final double cash;
  final double marketValue;
  final double floatingPnl;
  final double realizedPnl;
  final double totalPnl;
  final double dailyPnl;
  final double dailyPnlPercent;
  final List<EquityPoint> equityCurve;
  final List<BrokerBreakdown> brokerBreakdown;
  final List<AssetBreakdown> assetBreakdown;
  final List<PositionPnL> topWinners;
  final List<PositionPnL> topLosers;
  final List<String> notes;

  bool get hasHistory => equityCurve.isNotEmpty;

  factory PortfolioPerformance.fromJson(Map<String, dynamic> j) {
    List<T> arr<T>(String k, T Function(Map<String, dynamic>) f) =>
        (j[k] as List<dynamic>? ?? [])
            .map((e) => f(e as Map<String, dynamic>))
            .toList();
    return PortfolioPerformance(
      totalEquity: (j['total_equity'] as num?)?.toDouble() ?? 0,
      cash: (j['cash'] as num?)?.toDouble() ?? 0,
      marketValue: (j['market_value'] as num?)?.toDouble() ?? 0,
      floatingPnl: (j['floating_pnl'] as num?)?.toDouble() ?? 0,
      realizedPnl: (j['realized_pnl'] as num?)?.toDouble() ?? 0,
      totalPnl: (j['total_pnl'] as num?)?.toDouble() ?? 0,
      dailyPnl: (j['daily_pnl'] as num?)?.toDouble() ?? 0,
      dailyPnlPercent: (j['daily_pnl_percent'] as num?)?.toDouble() ?? 0,
      equityCurve: arr('equity_curve', EquityPoint.fromJson),
      brokerBreakdown: arr('broker_breakdown', BrokerBreakdown.fromJson),
      assetBreakdown: arr('asset_breakdown', AssetBreakdown.fromJson),
      topWinners: arr('top_winners', PositionPnL.fromJson),
      topLosers: arr('top_losers', PositionPnL.fromJson),
      notes: (j['notes'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

/// A non-fatal per-broker error (e.g. gateway down) from the portfolio.
class PortfolioBrokerError {
  const PortfolioBrokerError({required this.broker, required this.message});
  final String broker;
  final String message;

  factory PortfolioBrokerError.fromJson(Map<String, dynamic> j) =>
      PortfolioBrokerError(
        broker: j['broker'] as String? ?? '',
        message: j['message'] as String? ?? '',
      );
}

/// Unified portfolio: summary + positions (+ broker list / errors).
class UnifiedPortfolio {
  const UnifiedPortfolio({
    required this.summary,
    this.positions = const [],
    this.brokers = const [],
    this.errors = const [],
  });

  final PortfolioSummary summary;
  final List<PortfolioPosition> positions;
  final List<String> brokers;
  final List<PortfolioBrokerError> errors;

  factory UnifiedPortfolio.fromJson(Map<String, dynamic> j) => UnifiedPortfolio(
        summary: PortfolioSummary.fromJson(
            (j['summary'] as Map<String, dynamic>?) ?? const {}),
        positions: (j['positions'] as List<dynamic>? ?? [])
            .map((e) => PortfolioPosition.fromJson(e as Map<String, dynamic>))
            .toList(),
        brokers: (j['brokers'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        errors: (j['errors'] as List<dynamic>? ?? [])
            .map((e) =>
                PortfolioBrokerError.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
