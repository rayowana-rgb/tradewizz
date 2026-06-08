import 'market.dart';

/// Models for the simulated paper-trading portfolio (/v1/sim/*).
///
/// Every model carries [simulated] and the backend disclaimer so the UI can
/// never imply a real broker order is placed.

class SimAccount {
  const SimAccount({
    required this.cash,
    required this.equity,
    required this.buyingPower,
    required this.marketValue,
    required this.unrealizedPnl,
    required this.realizedPnl,
    required this.currency,
    required this.simulated,
    required this.disclaimer,
  });

  final double cash;
  final double equity;
  final double buyingPower;
  final double marketValue;
  final double unrealizedPnl;
  final double realizedPnl;
  final String currency;
  final bool simulated;
  final String disclaimer;

  factory SimAccount.fromJson(Map<String, dynamic> j) => SimAccount(
        cash: (j['cash'] as num?)?.toDouble() ?? 0,
        equity: (j['equity'] as num?)?.toDouble() ?? 0,
        buyingPower: (j['buying_power'] as num?)?.toDouble() ?? 0,
        marketValue: (j['market_value'] as num?)?.toDouble() ?? 0,
        unrealizedPnl: (j['unrealized_pnl'] as num?)?.toDouble() ?? 0,
        realizedPnl: (j['realized_pnl'] as num?)?.toDouble() ?? 0,
        currency: j['currency'] as String? ?? 'USD',
        simulated: j['simulated'] as bool? ?? true,
        disclaimer: j['disclaimer'] as String? ??
            'This is a simulated portfolio. No real broker order is sent.',
      );
}

class SimPosition {
  const SimPosition({
    required this.symbol,
    required this.market,
    required this.quantity,
    required this.averageCost,
    required this.lastPrice,
    required this.marketValue,
    required this.unrealizedPnl,
    required this.realizedPnl,
  });

  final String symbol;
  final Market market;
  final double quantity;
  final double averageCost;
  final double lastPrice;
  final double marketValue;
  final double unrealizedPnl;
  final double realizedPnl;

  factory SimPosition.fromJson(Map<String, dynamic> j) => SimPosition(
        symbol: j['symbol'] as String? ?? '',
        market: Market.values.firstWhere(
          (m) => m.code == (j['market'] as String?),
          orElse: () => Market.us,
        ),
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        averageCost: (j['average_cost'] as num?)?.toDouble() ?? 0,
        lastPrice: (j['last_price'] as num?)?.toDouble() ?? 0,
        marketValue: (j['market_value'] as num?)?.toDouble() ?? 0,
        unrealizedPnl: (j['unrealized_pnl'] as num?)?.toDouble() ?? 0,
        realizedPnl: (j['realized_pnl'] as num?)?.toDouble() ?? 0,
      );
}

class SimPortfolio {
  const SimPortfolio({
    required this.account,
    required this.positions,
    required this.simulated,
    required this.disclaimer,
  });

  final SimAccount account;
  final List<SimPosition> positions;
  final bool simulated;
  final String disclaimer;

  factory SimPortfolio.fromJson(Map<String, dynamic> j) => SimPortfolio(
        account: SimAccount.fromJson(
            (j['account'] as Map<String, dynamic>?) ?? const {}),
        positions: (j['positions'] as List<dynamic>? ?? [])
            .map((e) => SimPosition.fromJson(e as Map<String, dynamic>))
            .toList(),
        simulated: j['simulated'] as bool? ?? true,
        disclaimer: j['disclaimer'] as String? ??
            'This is a simulated portfolio. No real broker order is sent.',
      );
}

class SimTrade {
  const SimTrade({
    required this.orderId,
    required this.symbol,
    required this.market,
    required this.side,
    required this.quantity,
    required this.price,
    required this.value,
    required this.realizedPnl,
    required this.createdAt,
  });

  final String orderId;
  final String symbol;
  final Market market;
  final String side; // BUY / SELL
  final double quantity;
  final double price;
  final double value;
  final double realizedPnl;
  final String createdAt;

  factory SimTrade.fromJson(Map<String, dynamic> j) => SimTrade(
        orderId: j['order_id'] as String? ?? '',
        symbol: j['symbol'] as String? ?? '',
        market: Market.values.firstWhere(
          (m) => m.code == (j['market'] as String?),
          orElse: () => Market.us,
        ),
        side: j['side'] as String? ?? '',
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        price: (j['price'] as num?)?.toDouble() ?? 0,
        value: (j['value'] as num?)?.toDouble() ?? 0,
        realizedPnl: (j['realized_pnl'] as num?)?.toDouble() ?? 0,
        createdAt: j['created_at'] as String? ?? '',
      );
}

class SimOrderPreview {
  const SimOrderPreview({
    required this.symbol,
    required this.market,
    required this.side,
    required this.quantity,
    required this.orderType,
    required this.price,
    required this.estimatedValue,
    required this.currency,
    required this.cashAfter,
    required this.simulated,
    required this.warning,
  });

  final String symbol;
  final Market market;
  final String side;
  final double quantity;
  final String orderType;
  final double price;
  final double estimatedValue;
  final String currency;
  final double cashAfter;
  final bool simulated;
  final String warning;

  factory SimOrderPreview.fromJson(Map<String, dynamic> j) => SimOrderPreview(
        symbol: j['symbol'] as String? ?? '',
        market: Market.values.firstWhere(
          (m) => m.code == (j['market'] as String?),
          orElse: () => Market.us,
        ),
        side: j['side'] as String? ?? 'BUY',
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        orderType: j['order_type'] as String? ?? 'MARKET',
        price: (j['price'] as num?)?.toDouble() ?? 0,
        estimatedValue: (j['estimated_value'] as num?)?.toDouble() ?? 0,
        currency: j['currency'] as String? ?? 'USD',
        cashAfter: (j['cash_after'] as num?)?.toDouble() ?? 0,
        simulated: j['simulated'] as bool? ?? true,
        warning: j['warning'] as String? ??
            'Simulation only. No real broker order will be sent.',
      );
}

class SimOrderResult {
  const SimOrderResult({
    required this.orderId,
    required this.symbol,
    required this.market,
    required this.side,
    required this.quantity,
    required this.price,
    required this.value,
    required this.status,
    required this.realizedPnl,
    required this.cashAfter,
    required this.simulated,
    required this.message,
  });

  final String orderId;
  final String symbol;
  final Market market;
  final String side;
  final double quantity;
  final double price;
  final double value;
  final String status; // FILLED_SIMULATED
  final double realizedPnl;
  final double cashAfter;
  final bool simulated;
  final String message;

  factory SimOrderResult.fromJson(Map<String, dynamic> j) => SimOrderResult(
        orderId: j['order_id'] as String? ?? '',
        symbol: j['symbol'] as String? ?? '',
        market: Market.values.firstWhere(
          (m) => m.code == (j['market'] as String?),
          orElse: () => Market.us,
        ),
        side: j['side'] as String? ?? 'BUY',
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        price: (j['price'] as num?)?.toDouble() ?? 0,
        value: (j['value'] as num?)?.toDouble() ?? 0,
        status: j['status'] as String? ?? 'FILLED_SIMULATED',
        realizedPnl: (j['realized_pnl'] as num?)?.toDouble() ?? 0,
        cashAfter: (j['cash_after'] as num?)?.toDouble() ?? 0,
        simulated: j['simulated'] as bool? ?? true,
        message: j['message'] as String? ??
            'Simulated order filled. No real broker order was sent.',
      );
}
