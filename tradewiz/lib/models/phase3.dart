/// Models for Phase 3 (portfolio intelligence) features: Auto Watchlist AI,
/// Portfolio Rebalancing AI, and the Global Rotation Engine. Research/
/// simulation only — no broker data.
library;

import 'market.dart';

// =========================================================================
// Auto Watchlist AI
// =========================================================================
class AutoWatchlistSuggestion {
  const AutoWatchlistSuggestion({
    required this.symbol,
    required this.market,
    this.name = '',
    this.score = 0,
    this.signal = 'HOLD',
    this.origin = 'RADAR',
    this.reason = '',
    this.marketRegime = 'NEUTRAL',
    this.relativeStrength = 0,
    this.liquidity = 0,
    this.owned = false,
  });

  final String symbol;
  final Market market;
  final String name;
  final double score;
  final String signal;
  final String origin;
  final String reason;
  final String marketRegime;
  final double relativeStrength;
  final double liquidity;
  final bool owned;

  factory AutoWatchlistSuggestion.fromJson(Map<String, dynamic> j) {
    return AutoWatchlistSuggestion(
      symbol: (j['symbol'] ?? '').toString(),
      market: Market.fromCode((j['market'] ?? 'US').toString()),
      name: (j['name'] ?? '').toString(),
      score: (j['score'] ?? 0).toDouble(),
      signal: (j['signal'] ?? 'HOLD').toString(),
      origin: (j['origin'] ?? 'RADAR').toString(),
      reason: (j['reason'] ?? '').toString(),
      marketRegime: (j['market_regime'] ?? 'NEUTRAL').toString(),
      relativeStrength: (j['relative_strength'] ?? 0).toDouble(),
      liquidity: (j['liquidity'] ?? 0).toDouble(),
      owned: j['owned'] == true,
    );
  }
}

class AutoWatchlistSuggestions {
  const AutoWatchlistSuggestions({
    this.generatedAt = '',
    this.sessionDate = '',
    this.suggestions = const [],
    this.maxPerDay = 10,
    this.enabled = true,
  });

  final String generatedAt;
  final String sessionDate;
  final List<AutoWatchlistSuggestion> suggestions;
  final int maxPerDay;
  final bool enabled;

  factory AutoWatchlistSuggestions.fromJson(Map<String, dynamic> j) {
    return AutoWatchlistSuggestions(
      generatedAt: (j['generated_at'] ?? '').toString(),
      sessionDate: (j['session_date'] ?? '').toString(),
      suggestions: (j['suggestions'] as List<dynamic>? ?? [])
          .map(
            (e) => AutoWatchlistSuggestion.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
      maxPerDay: (j['max_suggestions_per_day'] ?? 10 as num).toInt(),
      enabled: j['enabled'] != false,
    );
  }
}

class AutoWatchlistSettings {
  const AutoWatchlistSettings({
    this.enabled = true,
    this.markets = const [],
    this.minScore = 85,
    this.maxPerDay = 10,
    this.includeMultibagger = true,
    this.includeDailyPicks = true,
  });

  final bool enabled;
  final List<Market> markets; // empty => all
  final double minScore;
  final int maxPerDay;
  final bool includeMultibagger;
  final bool includeDailyPicks;

  factory AutoWatchlistSettings.fromJson(Map<String, dynamic> j) {
    return AutoWatchlistSettings(
      enabled: j['enabled'] != false,
      markets: (j['markets'] as List<dynamic>? ?? [])
          .map((e) => Market.fromCode(e.toString()))
          .toList(),
      minScore: (j['min_score'] ?? 85).toDouble(),
      maxPerDay: (j['max_per_day'] ?? 10 as num).toInt(),
      includeMultibagger: j['include_multibagger'] != false,
      includeDailyPicks: j['include_daily_picks'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'markets': markets.map((m) => m.code).toList(),
    'min_score': minScore,
    'max_per_day': maxPerDay,
    'include_multibagger': includeMultibagger,
    'include_daily_picks': includeDailyPicks,
  };

  AutoWatchlistSettings copyWith({
    bool? enabled,
    List<Market>? markets,
    double? minScore,
    int? maxPerDay,
    bool? includeMultibagger,
    bool? includeDailyPicks,
  }) => AutoWatchlistSettings(
    enabled: enabled ?? this.enabled,
    markets: markets ?? this.markets,
    minScore: minScore ?? this.minScore,
    maxPerDay: maxPerDay ?? this.maxPerDay,
    includeMultibagger: includeMultibagger ?? this.includeMultibagger,
    includeDailyPicks: includeDailyPicks ?? this.includeDailyPicks,
  );
}

class AppliedSuggestion {
  const AppliedSuggestion({
    required this.symbol,
    required this.market,
    this.name = '',
    this.reason = '',
    this.scoreAtAdded = 0,
    this.marketRegimeAtAdded = 'NEUTRAL',
    this.addedAt = '',
  });

  final String symbol;
  final Market market;
  final String name;
  final String reason;
  final double scoreAtAdded;
  final String marketRegimeAtAdded;
  final String addedAt;

  factory AppliedSuggestion.fromJson(Map<String, dynamic> j) {
    return AppliedSuggestion(
      symbol: (j['symbol'] ?? '').toString(),
      market: Market.fromCode((j['market'] ?? 'US').toString()),
      name: (j['name'] ?? '').toString(),
      reason: (j['reason'] ?? '').toString(),
      scoreAtAdded: (j['score_at_added'] ?? 0).toDouble(),
      marketRegimeAtAdded: (j['market_regime_at_added'] ?? 'NEUTRAL')
          .toString(),
      addedAt: (j['added_at'] ?? '').toString(),
    );
  }
}

class ApplyResult {
  const ApplyResult({this.applied = const [], this.count = 0});

  final List<AppliedSuggestion> applied;
  final int count;

  factory ApplyResult.fromJson(Map<String, dynamic> j) {
    return ApplyResult(
      applied: (j['applied'] as List<dynamic>? ?? [])
          .map((e) => AppliedSuggestion.fromJson(e as Map<String, dynamic>))
          .toList(),
      count: (j['count'] ?? 0 as num).toInt(),
    );
  }
}

// =========================================================================
// Portfolio Rebalancing AI
// =========================================================================
class RebalanceAction {
  const RebalanceAction({
    required this.symbol,
    required this.market,
    this.name = '',
    this.action = 'HOLD',
    this.reason = '',
    this.currentWeight = 0,
    this.targetWeight = 0,
    this.priority = 'LOW',
    this.score = 0,
    this.qualityScore = 0,
    this.pnlPct = 0,
    this.pnlValue = 0,
  });

  final String symbol;
  final Market market;
  final String name;
  final String action; // ADD / HOLD / REDUCE / EXIT
  final String reason;
  final double currentWeight;
  final double targetWeight;
  final String priority; // HIGH / MEDIUM / LOW
  final double score;
  final double qualityScore;
  final double pnlPct; // unrealized P/L % on cost
  final double pnlValue; // unrealized P/L in account currency

  factory RebalanceAction.fromJson(Map<String, dynamic> j) {
    return RebalanceAction(
      symbol: (j['symbol'] ?? '').toString(),
      market: Market.fromCode((j['market'] ?? 'US').toString()),
      name: (j['name'] ?? '').toString(),
      action: (j['action'] ?? 'HOLD').toString(),
      reason: (j['reason'] ?? '').toString(),
      currentWeight: (j['current_weight'] ?? 0).toDouble(),
      targetWeight: (j['target_weight'] ?? 0).toDouble(),
      priority: (j['priority'] ?? 'LOW').toString(),
      score: (j['score'] ?? 0).toDouble(),
      qualityScore: (j['quality_score'] ?? 0).toDouble(),
      pnlPct: (j['pnl_pct'] ?? 0).toDouble(),
      pnlValue: (j['pnl_value'] ?? 0).toDouble(),
    );
  }
}

class RebalanceReport {
  const RebalanceReport({
    this.profile = 'Balanced',
    this.portfolioScore = 0,
    this.cashAllocation = 0,
    this.actions = const [],
    this.summary = '',
    this.warnings = const [],
    this.highPriorityCount = 0,
    this.estimatedScoreImprovement = 0,
  });

  final String profile;
  final double portfolioScore;
  final double cashAllocation;
  final List<RebalanceAction> actions;
  final String summary;
  final List<String> warnings;
  final int highPriorityCount;
  final double estimatedScoreImprovement;

  int get actionCount => actions.where((a) => a.action != 'HOLD').length;

  /// Drop any action for a symbol that is no longer held and recompute the
  /// derived counts. This is a client-side safety net against a stale cached
  /// report (e.g. an EXIT shown for a position that was already sold) — the
  /// backend only rebalances current holdings, so anything not in [heldKeys]
  /// must not be displayed. [heldKeys] are 'SYMBOL@MARKETCODE' identifiers.
  RebalanceReport reconciledWith(Set<String> heldKeys) {
    // No holdings info available -> show the report unchanged (best-effort).
    if (heldKeys.isEmpty) return this;
    final kept = actions
        .where((a) => heldKeys.contains('${a.symbol}@${a.market.code}'))
        .toList();
    if (kept.length == actions.length) return this;
    return RebalanceReport(
      profile: profile,
      portfolioScore: portfolioScore,
      cashAllocation: cashAllocation,
      actions: kept,
      summary: summary,
      warnings: warnings,
      highPriorityCount: kept
          .where((a) => a.priority == 'HIGH' && a.action != 'HOLD')
          .length,
      estimatedScoreImprovement: estimatedScoreImprovement,
    );
  }

  factory RebalanceReport.fromJson(Map<String, dynamic> j) {
    return RebalanceReport(
      profile: (j['profile'] ?? 'Balanced').toString(),
      portfolioScore: (j['portfolio_score'] ?? 0).toDouble(),
      cashAllocation: (j['cash_allocation'] ?? 0).toDouble(),
      actions: (j['actions'] as List<dynamic>? ?? [])
          .map((e) => RebalanceAction.fromJson(e as Map<String, dynamic>))
          .toList(),
      summary: (j['summary'] ?? '').toString(),
      warnings: (j['warnings'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      highPriorityCount: (j['high_priority_count'] ?? 0 as num).toInt(),
      estimatedScoreImprovement: (j['estimated_score_improvement'] ?? 0)
          .toDouble(),
    );
  }
}

// =========================================================================
// Global Rotation Engine
// =========================================================================
class MarketRotation {
  const MarketRotation({
    required this.market,
    this.rotationScore = 0,
    this.rank = 0,
    this.regime = 'NEUTRAL',
    this.topScoreAverage = 0,
    this.eliteCount = 0,
    this.strongCount = 0,
    this.breadth = 0,
    this.liquidity = 0,
    this.volatility = 0,
    this.recommendation = 'NEUTRAL',
  });

  final Market market;
  final double rotationScore;
  final int rank;
  final String regime;
  final double topScoreAverage;
  final int eliteCount;
  final int strongCount;
  final double breadth;
  final double liquidity;
  final double volatility;
  final String recommendation; // OVERWEIGHT / NEUTRAL / UNDERWEIGHT / AVOID

  factory MarketRotation.fromJson(Map<String, dynamic> j) {
    return MarketRotation(
      market: Market.fromCode((j['market'] ?? 'US').toString()),
      rotationScore: (j['rotation_score'] ?? 0).toDouble(),
      rank: (j['rank'] ?? 0 as num).toInt(),
      regime: (j['regime'] ?? 'NEUTRAL').toString(),
      topScoreAverage: (j['top_score_average'] ?? 0).toDouble(),
      eliteCount: (j['elite_count'] ?? 0 as num).toInt(),
      strongCount: (j['strong_count'] ?? 0 as num).toInt(),
      breadth: (j['breadth'] ?? 0).toDouble(),
      liquidity: (j['liquidity'] ?? 0).toDouble(),
      volatility: (j['volatility'] ?? 0).toDouble(),
      recommendation: (j['recommendation'] ?? 'NEUTRAL').toString(),
    );
  }
}

class GlobalRotation {
  const GlobalRotation({
    this.generatedAt = '',
    this.sessionDate = '',
    this.bestMarket = '',
    this.rotationSummary = '',
    this.markets = const [],
  });

  final String generatedAt;
  final String sessionDate;
  final String bestMarket;
  final String rotationSummary;
  final List<MarketRotation> markets;

  /// The single best market/index to be in right now. Prefers the entry whose
  /// code matches [bestMarket]; otherwise falls back to rank 1, then to the
  /// highest rotation score. Returns null when there is no rotation data.
  MarketRotation? get bestEntry {
    if (markets.isEmpty) return null;
    if (bestMarket.isNotEmpty) {
      for (final m in markets) {
        if (m.market.code.toUpperCase() == bestMarket.toUpperCase()) return m;
      }
    }
    final ranked = markets.where((m) => m.rank > 0).toList()
      ..sort((a, b) => a.rank.compareTo(b.rank));
    if (ranked.isNotEmpty) return ranked.first;
    final byScore = [...markets]
      ..sort((a, b) => b.rotationScore.compareTo(a.rotationScore));
    return byScore.first;
  }

  factory GlobalRotation.fromJson(Map<String, dynamic> j) {
    return GlobalRotation(
      generatedAt: (j['generated_at'] ?? '').toString(),
      sessionDate: (j['session_date'] ?? '').toString(),
      bestMarket: (j['best_market'] ?? '').toString(),
      rotationSummary: (j['rotation_summary'] ?? '').toString(),
      markets: (j['markets'] as List<dynamic>? ?? [])
          .map((e) => MarketRotation.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
