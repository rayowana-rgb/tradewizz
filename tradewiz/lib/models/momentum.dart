/// Momentum Research models (EXPERIMENTAL, Stage-3b).
///
/// Mirrors the backend `/v1/momentum/*` payloads. This is a research-stage
/// signal (long-only 12-1 momentum, monthly hold, no tight stop) that passed
/// historical out-of-sample but is NOT live-validated. The UI always surfaces
/// the [MomentumPicks.disclaimer].
library;

class MomentumPick {
  const MomentumPick({
    required this.symbol,
    required this.rank,
    required this.momentum,
    required this.lastPrice,
    required this.medianDollarVol,
  });

  final String symbol;
  final int rank;

  /// 12-1 total return as a decimal (e.g. 0.35 == +35%).
  final double momentum;
  final double lastPrice;
  final double medianDollarVol;

  factory MomentumPick.fromJson(Map<String, dynamic> j) => MomentumPick(
        symbol: (j['symbol'] ?? '').toString(),
        rank: (j['rank'] as num?)?.toInt() ?? 0,
        momentum: (j['momentum'] as num?)?.toDouble() ?? 0.0,
        lastPrice: (j['last_price'] as num?)?.toDouble() ?? 0.0,
        medianDollarVol: (j['median_dollar_vol'] as num?)?.toDouble() ?? 0.0,
      );
}

class MomentumPicks {
  const MomentumPicks({
    required this.picks,
    required this.universeSize,
    required this.tradableSize,
    required this.topN,
    required this.regime,
    required this.regimeNote,
    required this.stage,
    required this.disclaimer,
    required this.generatedAt,
  });

  final List<MomentumPick> picks;
  final int universeSize;
  final int tradableSize;
  final int topN;

  /// "bull" | "stress" | "unknown".
  final String regime;
  final String regimeNote;
  final String stage;
  final String disclaimer;
  final String generatedAt;

  bool get isStress => regime == 'stress';

  factory MomentumPicks.fromJson(Map<String, dynamic> j) => MomentumPicks(
        picks: ((j['picks'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MomentumPick.fromJson)
            .toList(),
        universeSize: (j['universe_size'] as num?)?.toInt() ?? 0,
        tradableSize: (j['tradable_size'] as num?)?.toInt() ?? 0,
        topN: (j['top_n'] as num?)?.toInt() ?? 0,
        regime: (j['regime'] ?? 'unknown').toString(),
        regimeNote: (j['regime_note'] ?? '').toString(),
        stage: (j['stage'] ?? '').toString(),
        disclaimer: (j['disclaimer'] ?? '').toString(),
        generatedAt: (j['generated_at'] ?? '').toString(),
      );
}

class MomentumBasketLeg {
  const MomentumBasketLeg({
    required this.symbol,
    required this.lastPrice,
    required this.quantity,
    required this.estNotional,
  });

  final String symbol;
  final double lastPrice;
  final double quantity;
  final double estNotional;

  factory MomentumBasketLeg.fromJson(Map<String, dynamic> j) =>
      MomentumBasketLeg(
        symbol: (j['symbol'] ?? '').toString(),
        lastPrice: (j['last_price'] as num?)?.toDouble() ?? 0.0,
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0.0,
        estNotional: (j['est_notional'] as num?)?.toDouble() ?? 0.0,
      );
}

class MomentumBasketPreview {
  const MomentumBasketPreview({
    required this.legs,
    required this.perPositionUsd,
    required this.totalEstNotional,
    required this.maxNotionalPerOrder,
    required this.disclaimer,
  });

  final List<MomentumBasketLeg> legs;
  final double perPositionUsd;
  final double totalEstNotional;
  final double maxNotionalPerOrder;
  final String disclaimer;

  factory MomentumBasketPreview.fromJson(Map<String, dynamic> j) =>
      MomentumBasketPreview(
        legs: ((j['legs'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MomentumBasketLeg.fromJson)
            .toList(),
        perPositionUsd: (j['per_position_usd'] as num?)?.toDouble() ?? 0.0,
        totalEstNotional: (j['total_est_notional'] as num?)?.toDouble() ?? 0.0,
        maxNotionalPerOrder:
            (j['max_notional_per_order'] as num?)?.toDouble() ?? 0.0,
        disclaimer: (j['disclaimer'] ?? '').toString(),
      );
}

class MomentumBasketLegResult {
  const MomentumBasketLegResult({
    required this.symbol,
    required this.ok,
    this.orderId,
    this.quantity = 0.0,
    this.status,
    this.error,
  });

  final String symbol;
  final bool ok;
  final String? orderId;
  final double quantity;
  final String? status;
  final String? error;

  factory MomentumBasketLegResult.fromJson(Map<String, dynamic> j) =>
      MomentumBasketLegResult(
        symbol: (j['symbol'] ?? '').toString(),
        ok: j['ok'] == true,
        orderId: j['order_id']?.toString(),
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0.0,
        status: j['status']?.toString(),
        error: j['error']?.toString(),
      );
}

class MomentumBasketResult {
  const MomentumBasketResult({
    required this.live,
    required this.placed,
    required this.failed,
    required this.legs,
  });

  final bool live;
  final int placed;
  final int failed;
  final List<MomentumBasketLegResult> legs;

  factory MomentumBasketResult.fromJson(Map<String, dynamic> j) =>
      MomentumBasketResult(
        live: j['live'] == true,
        placed: (j['placed'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        legs: ((j['legs'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MomentumBasketLegResult.fromJson)
            .toList(),
      );
}

/// One SELL leg of a monthly rebalance: a momentum-held name that dropped out
/// of the fresh top-N and should be fully closed.
class MomentumRebalanceSell {
  const MomentumRebalanceSell({
    required this.symbol,
    required this.quantity,
    required this.lastPrice,
    required this.estNotional,
  });

  final String symbol;
  final double quantity;
  final double lastPrice;
  final double estNotional;

  factory MomentumRebalanceSell.fromJson(Map<String, dynamic> j) =>
      MomentumRebalanceSell(
        symbol: (j['symbol'] ?? '').toString(),
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0.0,
        lastPrice: (j['last_price'] as num?)?.toDouble() ?? 0.0,
        estNotional: (j['est_notional'] as num?)?.toDouble() ?? 0.0,
      );
}

/// One BUY leg of a monthly rebalance: a fresh top-N name not yet held.
class MomentumRebalanceBuy {
  const MomentumRebalanceBuy({
    required this.symbol,
    required this.rank,
    required this.quantity,
    required this.lastPrice,
    required this.estNotional,
  });

  final String symbol;
  final int rank;
  final double quantity;
  final double lastPrice;
  final double estNotional;

  factory MomentumRebalanceBuy.fromJson(Map<String, dynamic> j) =>
      MomentumRebalanceBuy(
        symbol: (j['symbol'] ?? '').toString(),
        rank: (j['rank'] as num?)?.toInt() ?? 0,
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0.0,
        lastPrice: (j['last_price'] as num?)?.toDouble() ?? 0.0,
        estNotional: (j['est_notional'] as num?)?.toDouble() ?? 0.0,
      );
}

/// The full monthly-rebalance plan: what to sell, buy, and hold.
class MomentumRebalancePreview {
  const MomentumRebalancePreview({
    required this.sells,
    required this.buys,
    required this.holds,
    required this.perPositionUsd,
    required this.maxNotionalPerOrder,
    required this.disclaimer,
  });

  final List<MomentumRebalanceSell> sells;
  final List<MomentumRebalanceBuy> buys;
  final List<String> holds;
  final double perPositionUsd;
  final double maxNotionalPerOrder;
  final String disclaimer;

  bool get isEmpty => sells.isEmpty && buys.isEmpty;

  factory MomentumRebalancePreview.fromJson(Map<String, dynamic> j) =>
      MomentumRebalancePreview(
        sells: ((j['sells'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MomentumRebalanceSell.fromJson)
            .toList(),
        buys: ((j['buys'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MomentumRebalanceBuy.fromJson)
            .toList(),
        holds: ((j['holds'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        perPositionUsd: (j['per_position_usd'] as num?)?.toDouble() ?? 0.0,
        maxNotionalPerOrder:
            (j['max_notional_per_order'] as num?)?.toDouble() ?? 0.0,
        disclaimer: (j['disclaimer'] ?? '').toString(),
      );
}

/// One live position that momentum bought (ledger ∩ live), with P/L.
class MomentumHolding {
  const MomentumHolding({
    required this.symbol,
    required this.qty,
    required this.costPrice,
    required this.lastPrice,
    required this.marketValue,
    required this.unrealizedPl,
    required this.unrealizedPlRatio,
    required this.inTopN,
    this.rank,
    required this.firstBoughtTs,
  });

  final String symbol;
  final double qty;
  final double costPrice;
  final double lastPrice;
  final double marketValue;
  final double unrealizedPl;

  /// Fraction, e.g. 0.086 == +8.6%.
  final double unrealizedPlRatio;

  /// Still in the current top-N (would be a HOLD at the next rebalance).
  final bool inTopN;
  final int? rank;
  final int firstBoughtTs;

  factory MomentumHolding.fromJson(Map<String, dynamic> j) => MomentumHolding(
        symbol: (j['symbol'] ?? '').toString(),
        qty: (j['qty'] as num?)?.toDouble() ?? 0.0,
        costPrice: (j['cost_price'] as num?)?.toDouble() ?? 0.0,
        lastPrice: (j['last_price'] as num?)?.toDouble() ?? 0.0,
        marketValue: (j['market_value'] as num?)?.toDouble() ?? 0.0,
        unrealizedPl: (j['unrealized_pl'] as num?)?.toDouble() ?? 0.0,
        unrealizedPlRatio:
            (j['unrealized_pl_ratio'] as num?)?.toDouble() ?? 0.0,
        inTopN: j['in_top_n'] == true,
        rank: (j['rank'] as num?)?.toInt(),
        firstBoughtTs: (j['first_bought_ts'] as num?)?.toInt() ?? 0,
      );
}

/// The momentum-owned portfolio: live positions momentum bought + totals.
class MomentumHoldings {
  const MomentumHoldings({
    required this.holdings,
    required this.totalMarketValue,
    required this.totalUnrealizedPl,
    required this.topN,
    required this.staleSymbols,
    required this.generatedAt,
  });

  final List<MomentumHolding> holdings;
  final double totalMarketValue;
  final double totalUnrealizedPl;
  final int topN;

  /// Ledger names no longer held live (sold manually elsewhere).
  final List<String> staleSymbols;
  final String generatedAt;

  bool get isEmpty => holdings.isEmpty;

  factory MomentumHoldings.fromJson(Map<String, dynamic> j) => MomentumHoldings(
        holdings: ((j['holdings'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MomentumHolding.fromJson)
            .toList(),
        totalMarketValue:
            (j['total_market_value'] as num?)?.toDouble() ?? 0.0,
        totalUnrealizedPl:
            (j['total_unrealized_pl'] as num?)?.toDouble() ?? 0.0,
        topN: (j['top_n'] as num?)?.toInt() ?? 0,
        staleSymbols: ((j['stale_symbols'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        generatedAt: (j['generated_at'] ?? '').toString(),
      );
}
