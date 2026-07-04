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
