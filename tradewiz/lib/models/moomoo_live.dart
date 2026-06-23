// Models for the PRIVATE Moomoo live-trading bridge (/v1/broker/moomoo/*).
//
// These mirror the backend `app/moomoo/models.py` shapes. They are only used
// by the owner-only live trading screen.

class MoomooLiveAccount {
  const MoomooLiveAccount({
    this.totalAssets = 0,
    this.cash = 0,
    this.buyingPower = 0,
    this.marketValue = 0,
    this.currency = 'USD',
  });

  final double totalAssets;
  final double cash;
  final double buyingPower;
  final double marketValue;
  final String currency;

  factory MoomooLiveAccount.fromJson(Map<String, dynamic> j) =>
      MoomooLiveAccount(
        totalAssets: (j['total_assets'] as num?)?.toDouble() ?? 0,
        cash: (j['cash'] as num?)?.toDouble() ?? 0,
        buyingPower: (j['buying_power'] as num?)?.toDouble() ?? 0,
        marketValue: (j['market_value'] as num?)?.toDouble() ?? 0,
        currency: j['currency'] as String? ?? 'USD',
      );
}

class MoomooLivePosition {
  const MoomooLivePosition({
    this.code = '',
    this.symbol = '',
    this.quantity = 0,
    this.canSellQty = 0,
    this.costPrice = 0,
    this.lastPrice = 0,
    this.plVal = 0,
    this.plRatio = 0,
  });

  final String code;
  final String symbol;
  final double quantity;
  final double canSellQty;
  final double costPrice;
  final double lastPrice;
  final double plVal;
  final double plRatio;

  factory MoomooLivePosition.fromJson(Map<String, dynamic> j) =>
      MoomooLivePosition(
        code: j['code'] as String? ?? '',
        symbol: j['symbol'] as String? ?? '',
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        canSellQty: (j['can_sell_qty'] as num?)?.toDouble() ?? 0,
        costPrice: (j['cost_price'] as num?)?.toDouble() ?? 0,
        lastPrice: (j['last_price'] as num?)?.toDouble() ?? 0,
        plVal: (j['pl_val'] as num?)?.toDouble() ?? 0,
        plRatio: (j['pl_ratio'] as num?)?.toDouble() ?? 0,
      );
}

class MoomooLivePreview {
  const MoomooLivePreview({
    this.code = '',
    this.symbol = '',
    this.side = 'BUY',
    this.orderType = 'MARKET',
    this.quantity = 0,
    this.price = 0,
    this.estNotional = 0,
    this.maxNotional = 0,
    this.withinCap = false,
    this.currency = 'USD',
  });

  final String code;
  final String symbol;
  final String side;
  final String orderType;
  final double quantity;
  final double price;
  final double estNotional;
  final double maxNotional;
  final bool withinCap;
  final String currency;

  factory MoomooLivePreview.fromJson(Map<String, dynamic> j) =>
      MoomooLivePreview(
        code: j['code'] as String? ?? '',
        symbol: j['symbol'] as String? ?? '',
        side: j['side'] as String? ?? 'BUY',
        orderType: j['order_type'] as String? ?? 'MARKET',
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        price: (j['price'] as num?)?.toDouble() ?? 0,
        estNotional: (j['est_notional'] as num?)?.toDouble() ?? 0,
        maxNotional: (j['max_notional'] as num?)?.toDouble() ?? 0,
        withinCap: j['within_cap'] as bool? ?? false,
        currency: j['currency'] as String? ?? 'USD',
      );
}

class MoomooLiveOrderResult {
  const MoomooLiveOrderResult({
    this.orderId = '',
    this.code = '',
    this.side = '',
    this.orderType = '',
    this.quantity = 0,
    this.price = 0,
    this.status = '',
  });

  final String orderId;
  final String code;
  final String side;
  final String orderType;
  final double quantity;
  final double price;
  final String status;

  factory MoomooLiveOrderResult.fromJson(Map<String, dynamic> j) =>
      MoomooLiveOrderResult(
        orderId: j['order_id'] as String? ?? '',
        code: j['code'] as String? ?? '',
        side: j['side'] as String? ?? '',
        orderType: j['order_type'] as String? ?? '',
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        price: (j['price'] as num?)?.toDouble() ?? 0,
        status: j['status'] as String? ?? '',
      );
}

class MoomooLiveManagerRec {
  const MoomooLiveManagerRec({
    required this.kind,
    required this.severity,
    required this.title,
    required this.message,
    this.symbol,
  });

  final String kind;
  final String severity; // info / warning / critical
  final String title;
  final String message;
  final String? symbol;

  factory MoomooLiveManagerRec.fromJson(Map<String, dynamic> j) =>
      MoomooLiveManagerRec(
        kind: j['kind'] as String? ?? '',
        severity: j['severity'] as String? ?? 'info',
        title: j['title'] as String? ?? '',
        message: j['message'] as String? ?? '',
        symbol: j['symbol'] as String?,
      );
}

class MoomooLiveManagerReport {
  const MoomooLiveManagerReport({
    this.riskLevel = 'MODERATE',
    this.concentrationScore = 0,
    this.diversificationScore = 0,
    this.cashPct = 0,
    this.largestPositionPct = 0,
    this.holdingsCount = 0,
    this.recommendations = const [],
  });

  final String riskLevel; // LOW / MODERATE / HIGH
  final double concentrationScore;
  final double diversificationScore;
  final double cashPct;
  final double largestPositionPct;
  final int holdingsCount;
  final List<MoomooLiveManagerRec> recommendations;

  factory MoomooLiveManagerReport.fromJson(Map<String, dynamic> j) =>
      MoomooLiveManagerReport(
        riskLevel: j['risk_level'] as String? ?? 'MODERATE',
        concentrationScore:
            (j['concentration_score'] as num?)?.toDouble() ?? 0,
        diversificationScore:
            (j['diversification_score'] as num?)?.toDouble() ?? 0,
        cashPct: (j['cash_pct'] as num?)?.toDouble() ?? 0,
        largestPositionPct:
            (j['largest_position_pct'] as num?)?.toDouble() ?? 0,
        holdingsCount: (j['holdings_count'] as num?)?.toInt() ?? 0,
        recommendations: (j['recommendations'] as List<dynamic>? ?? [])
            .map((e) =>
                MoomooLiveManagerRec.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
