import 'market.dart';

/// Order side.
enum OrderSide { buy, sell }

extension OrderSideX on OrderSide {
  String get wire => this == OrderSide.buy ? 'BUY' : 'SELL';
  String get label => this == OrderSide.buy ? 'Buy' : 'Sell';
}

/// Order type.
enum OrderTypeKind { market, limit }

extension OrderTypeKindX on OrderTypeKind {
  String get wire => this == OrderTypeKind.market ? 'MARKET' : 'LIMIT';
  String get label => this == OrderTypeKind.market ? 'Market' : 'Limit';
}

/// Broker connection / trading-env status (GET /v1/broker/status).
class BrokerStatus {
  const BrokerStatus({
    required this.connected,
    required this.tradingEnv,
    required this.isReal,
    this.warning,
    this.message = '',
  });

  final bool connected;
  final String tradingEnv; // PAPER / REAL
  final bool isReal;
  final String? warning;
  final String message;

  factory BrokerStatus.fromJson(Map<String, dynamic> j) => BrokerStatus(
        connected: j['connected'] as bool? ?? false,
        tradingEnv: j['trading_env'] as String? ?? 'PAPER',
        isReal: j['is_real'] as bool? ?? false,
        warning: j['warning'] as String?,
        message: j['message'] as String? ?? '',
      );
}

/// Order preview (POST /v1/broker/order/preview).
class OrderPreview {
  const OrderPreview({
    required this.symbol,
    required this.market,
    required this.moomooCode,
    required this.side,
    required this.quantity,
    required this.orderType,
    required this.price,
    required this.estimatedValue,
    required this.currency,
    required this.tradingEnv,
    required this.isReal,
    required this.confirmationToken,
    required this.expiresInSeconds,
    required this.warnings,
  });

  final String symbol;
  final Market market;
  final String moomooCode;
  final OrderSide side;
  final double quantity;
  final OrderTypeKind orderType;
  final double? price;
  final double estimatedValue;
  final String currency;
  final String tradingEnv;
  final bool isReal;
  final String confirmationToken;
  final double expiresInSeconds;
  final List<String> warnings;

  factory OrderPreview.fromJson(Map<String, dynamic> j) => OrderPreview(
        symbol: j['symbol'] as String? ?? '',
        market: Market.values.firstWhere(
          (m) => m.code == (j['market'] as String?),
          orElse: () => Market.hkex,
        ),
        moomooCode: j['moomoo_code'] as String? ?? '',
        side: (j['side'] as String?) == 'SELL'
            ? OrderSide.sell
            : OrderSide.buy,
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        orderType: (j['order_type'] as String?) == 'MARKET'
            ? OrderTypeKind.market
            : OrderTypeKind.limit,
        price: (j['price'] as num?)?.toDouble(),
        estimatedValue: (j['estimated_value'] as num?)?.toDouble() ?? 0,
        currency: j['currency'] as String? ?? '',
        tradingEnv: j['trading_env'] as String? ?? 'PAPER',
        isReal: j['is_real'] as bool? ?? false,
        confirmationToken: j['confirmation_token'] as String? ?? '',
        expiresInSeconds: (j['expires_in_seconds'] as num?)?.toDouble() ?? 120,
        warnings: (j['warnings'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// Result of placing an order (POST /v1/broker/order/place).
class OrderResult {
  const OrderResult({
    required this.orderId,
    required this.symbol,
    required this.side,
    required this.quantity,
    required this.status,
    required this.tradingEnv,
    required this.isReal,
    this.message = '',
  });

  final String orderId;
  final String symbol;
  final OrderSide side;
  final double quantity;
  final String status;
  final String tradingEnv;
  final bool isReal;
  final String message;

  factory OrderResult.fromJson(Map<String, dynamic> j) => OrderResult(
        orderId: j['order_id'] as String? ?? '',
        symbol: j['symbol'] as String? ?? '',
        side: (j['side'] as String?) == 'SELL'
            ? OrderSide.sell
            : OrderSide.buy,
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        status: j['status'] as String? ?? '',
        tradingEnv: j['trading_env'] as String? ?? 'PAPER',
        isReal: j['is_real'] as bool? ?? false,
        message: j['message'] as String? ?? '',
      );
}
