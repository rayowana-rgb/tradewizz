import 'market.dart';

/// Subscription tiers. Mirrors the backend FREE / PRO / ELITE.
enum Tier {
  free('FREE', 'Free', 0.0),
  pro('PRO', 'Pro', 9.99),
  elite('ELITE', 'Elite', 29.99);

  const Tier(this.code, this.label, this.priceUsdMonth);
  final String code;
  final String label;
  final double priceUsdMonth;

  static Tier fromCode(String? code) {
    final c = (code ?? 'FREE').toUpperCase();
    return Tier.values.firstWhere(
      (t) => t.code == c,
      orElse: () => Tier.free,
    );
  }

  /// Rank for "is at least" comparisons (free < pro < elite).
  int get rank => index;

  bool atLeast(Tier other) => rank >= other.rank;
}

/// Stable feature keys (mirror the backend entitlements).
class Features {
  static const globalMarkets = 'global_markets';
  static const advancedScore = 'advanced_score_breakdown';
  static const opportunityRadar = 'opportunity_radar';
  static const dailyPicks = 'daily_top_opportunities';
  static const multibagger = 'multibagger_finder';
  static const portfolioHealth = 'portfolio_health';
  static const riskAnalysis = 'risk_analysis';
  static const concentration = 'concentration_analysis';
  static const exitWarnings = 'exit_warnings';
  static const positionQuality = 'position_quality';
  static const eliteOpportunities = 'elite_opportunities';
}

const int unlimited = -1;

class TierLimits {
  const TierLimits({
    required this.watchlistMax,
    required this.analysisPerDay,
    required this.screenerMaxResults,
  });

  final int watchlistMax;
  final int analysisPerDay;
  final int screenerMaxResults;

  bool get watchlistUnlimited => watchlistMax == unlimited;
  bool get analysisUnlimited => analysisPerDay == unlimited;
  bool get screenerUnlimited => screenerMaxResults == unlimited;

  factory TierLimits.fromJson(Map<String, dynamic> j) => TierLimits(
        watchlistMax: (j['watchlist_max'] ?? unlimited) as int,
        analysisPerDay: (j['analysis_per_day'] ?? unlimited) as int,
        screenerMaxResults: (j['screener_max_results'] ?? unlimited) as int,
      );
}

class UsageToday {
  const UsageToday({
    required this.analysisCount,
    required this.analysisLimit,
    required this.analysisRemaining,
  });

  final int analysisCount;
  final int analysisLimit;
  final int analysisRemaining;

  bool get analysisUnlimited => analysisLimit == unlimited;

  factory UsageToday.fromJson(Map<String, dynamic> j) => UsageToday(
        analysisCount: (j['analysis_count'] ?? 0) as int,
        analysisLimit: (j['analysis_limit'] ?? 0) as int,
        analysisRemaining: (j['analysis_remaining'] ?? unlimited) as int,
      );
}

/// The app's view of what the current user may do (from GET /entitlements).
class Entitlements {
  const Entitlements({
    required this.tier,
    required this.active,
    required this.limits,
    required this.features,
    required this.usage,
    this.expiresAt,
  });

  final Tier tier;
  final bool active;
  final TierLimits limits;
  final Set<String> features;
  final UsageToday usage;
  final String? expiresAt;

  bool has(String feature) => features.contains(feature);

  /// FREE defaults so the UI can render before the network resolves.
  static const Entitlements free = Entitlements(
    tier: Tier.free,
    active: true,
    limits: TierLimits(
      watchlistMax: 20,
      analysisPerDay: 5,
      screenerMaxResults: 20,
    ),
    features: {Features.globalMarkets},
    usage: UsageToday(
      analysisCount: 0,
      analysisLimit: 5,
      analysisRemaining: 5,
    ),
  );

  factory Entitlements.fromJson(Map<String, dynamic> j) => Entitlements(
        tier: Tier.fromCode(j['tier'] as String?),
        active: (j['active'] ?? true) as bool,
        limits:
            TierLimits.fromJson((j['limits'] ?? const {}) as Map<String, dynamic>),
        features: ((j['features'] ?? const []) as List)
            .map((e) => e.toString())
            .toSet(),
        usage:
            UsageToday.fromJson((j['usage'] ?? const {}) as Map<String, dynamic>),
        expiresAt: j['expires_at'] as String?,
      );
}

/// One row in the plan comparison table.
class PlanFeatureRow {
  const PlanFeatureRow({
    required this.key,
    required this.label,
    required this.minTier,
    required this.tiers,
  });

  final String key;
  final String label;
  final Tier minTier;
  final Map<Tier, bool> tiers;

  factory PlanFeatureRow.fromJson(Map<String, dynamic> j) {
    final raw = (j['tiers'] ?? const {}) as Map<String, dynamic>;
    return PlanFeatureRow(
      key: j['key'] as String,
      label: (j['label'] ?? j['key']) as String,
      minTier: Tier.fromCode(j['min_tier'] as String?),
      tiers: {
        for (final t in Tier.values) t: (raw[t.code] ?? false) as bool,
      },
    );
  }
}

class PlanTier {
  const PlanTier({
    required this.tier,
    required this.priceUsdMonth,
    required this.description,
    required this.limits,
    required this.features,
  });

  final Tier tier;
  final double priceUsdMonth;
  final String description;
  final TierLimits limits;
  final Set<String> features;

  factory PlanTier.fromJson(Map<String, dynamic> j) => PlanTier(
        tier: Tier.fromCode(j['tier'] as String?),
        priceUsdMonth: ((j['price_usd_month'] ?? 0) as num).toDouble(),
        description: (j['description'] ?? '') as String,
        limits: TierLimits.fromJson(
            (j['limits'] ?? const {}) as Map<String, dynamic>),
        features: ((j['features'] ?? const []) as List)
            .map((e) => e.toString())
            .toSet(),
      );
}

class PlanComparison {
  const PlanComparison({required this.tiers, required this.features});

  final List<PlanTier> tiers;
  final List<PlanFeatureRow> features;

  factory PlanComparison.fromJson(Map<String, dynamic> j) => PlanComparison(
        tiers: ((j['tiers'] ?? const []) as List)
            .map((e) => PlanTier.fromJson(e as Map<String, dynamic>))
            .toList(),
        features: ((j['features'] ?? const []) as List)
            .map((e) => PlanFeatureRow.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// --- Radar models -----------------------------------------------------------

class Opportunity {
  const Opportunity({
    required this.symbol,
    required this.market,
    required this.name,
    required this.score,
    required this.signal,
    required this.recommendation,
    required this.opportunityReason,
    required this.marketRegime,
  });

  final String symbol;
  final Market market;
  final String name;
  final double score;
  final String signal;
  final String recommendation;
  final String opportunityReason;
  final String marketRegime;

  factory Opportunity.fromJson(Map<String, dynamic> j) => Opportunity(
        symbol: j['symbol'] as String,
        market: Market.fromCode(j['market'] as String),
        name: (j['name'] ?? '') as String,
        score: ((j['score'] ?? 0) as num).toDouble(),
        signal: (j['signal'] ?? 'HOLD') as String,
        recommendation: (j['recommendation'] ?? '') as String,
        opportunityReason: (j['opportunity_reason'] ?? '') as String,
        marketRegime: (j['market_regime'] ?? 'NEUTRAL') as String,
      );
}

class OpportunitiesResult {
  const OpportunitiesResult({
    required this.globalTop10,
    required this.usTop10,
    required this.idxTop10,
    required this.multibaggerCandidates,
  });

  final List<Opportunity> globalTop10;
  final List<Opportunity> usTop10;
  final List<Opportunity> idxTop10;
  final List<Opportunity> multibaggerCandidates;

  static List<Opportunity> _list(dynamic v) =>
      ((v ?? const []) as List)
          .map((e) => Opportunity.fromJson(e as Map<String, dynamic>))
          .toList();

  factory OpportunitiesResult.fromJson(Map<String, dynamic> j) =>
      OpportunitiesResult(
        globalTop10: _list(j['global_top10']),
        usTop10: _list(j['us_top10']),
        idxTop10: _list(j['idx_top10']),
        multibaggerCandidates: _list(j['multibagger_candidates']),
      );
}

class DailyPick {
  const DailyPick({
    required this.rank,
    required this.symbol,
    required this.market,
    required this.name,
    required this.score,
    required this.signal,
    required this.recommendation,
  });

  final int rank;
  final String symbol;
  final Market market;
  final String name;
  final double score;
  final String signal;
  final String recommendation;

  factory DailyPick.fromJson(Map<String, dynamic> j) => DailyPick(
        rank: (j['rank'] ?? 0) as int,
        symbol: j['symbol'] as String,
        market: Market.fromCode(j['market'] as String),
        name: (j['name'] ?? '') as String,
        score: ((j['score'] ?? 0) as num).toDouble(),
        signal: (j['signal'] ?? 'HOLD') as String,
        recommendation: (j['recommendation'] ?? '') as String,
      );
}

class DailyPicks {
  const DailyPicks({required this.title, required this.picks, required this.date});
  final String title;
  final String date;
  final List<DailyPick> picks;

  factory DailyPicks.fromJson(Map<String, dynamic> j) => DailyPicks(
        title: (j['title'] ?? "Today's Top Opportunities") as String,
        date: (j['date'] ?? '') as String,
        picks: ((j['picks'] ?? const []) as List)
            .map((e) => DailyPick.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class MultibaggerCandidate {
  const MultibaggerCandidate({
    required this.symbol,
    required this.market,
    required this.name,
    required this.score,
    required this.conviction,
    required this.riskLevel,
    required this.reason,
  });

  final String symbol;
  final Market market;
  final String name;
  final double score;
  final String conviction;
  final String riskLevel;
  final String reason;

  factory MultibaggerCandidate.fromJson(Map<String, dynamic> j) =>
      MultibaggerCandidate(
        symbol: j['symbol'] as String,
        market: Market.fromCode(j['market'] as String),
        name: (j['name'] ?? '') as String,
        score: ((j['score'] ?? 0) as num).toDouble(),
        conviction: (j['conviction'] ?? 'MODERATE') as String,
        riskLevel: (j['risk_level'] ?? 'HIGH') as String,
        reason: (j['reason'] ?? '') as String,
      );
}

class MultibaggerResult {
  const MultibaggerResult({required this.criteria, required this.candidates});
  final List<String> criteria;
  final List<MultibaggerCandidate> candidates;

  factory MultibaggerResult.fromJson(Map<String, dynamic> j) => MultibaggerResult(
        criteria: ((j['criteria'] ?? const []) as List)
            .map((e) => e.toString())
            .toList(),
        candidates: ((j['candidates'] ?? const []) as List)
            .map((e) => MultibaggerCandidate.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// --- Portfolio Health models ------------------------------------------------

class HealthComponents {
  const HealthComponents({
    required this.diversification,
    required this.concentrationRisk,
    required this.liquidity,
    required this.quality,
    required this.sectorExposure,
  });

  final double diversification;
  final double concentrationRisk;
  final double liquidity;
  final double quality;
  final double sectorExposure;

  factory HealthComponents.fromJson(Map<String, dynamic> j) => HealthComponents(
        diversification: ((j['diversification'] ?? 0) as num).toDouble(),
        concentrationRisk: ((j['concentration_risk'] ?? 0) as num).toDouble(),
        liquidity: ((j['liquidity'] ?? 0) as num).toDouble(),
        quality: ((j['quality'] ?? 0) as num).toDouble(),
        sectorExposure: ((j['sector_exposure'] ?? 0) as num).toDouble(),
      );
}

class PositionQuality {
  const PositionQuality({
    required this.symbol,
    required this.market,
    required this.qualityScore,
    required this.rating,
    required this.note,
  });

  final String symbol;
  final Market market;
  final double qualityScore;
  final String rating;
  final String note;

  factory PositionQuality.fromJson(Map<String, dynamic> j) => PositionQuality(
        symbol: j['symbol'] as String,
        market: Market.fromCode(j['market'] as String),
        qualityScore: ((j['quality_score'] ?? 0) as num).toDouble(),
        rating: (j['rating'] ?? '') as String,
        note: (j['note'] ?? '') as String,
      );
}

class PortfolioHealth {
  const PortfolioHealth({
    required this.healthScore,
    required this.rating,
    required this.components,
    required this.warnings,
    required this.strengths,
    required this.exitWarnings,
    required this.positions,
  });

  final double healthScore;
  final String rating;
  final HealthComponents components;
  final List<String> warnings;
  final List<String> strengths;
  final List<String> exitWarnings;
  final List<PositionQuality> positions;

  factory PortfolioHealth.fromJson(Map<String, dynamic> j) => PortfolioHealth(
        healthScore: ((j['health_score'] ?? 0) as num).toDouble(),
        rating: (j['rating'] ?? '') as String,
        components: HealthComponents.fromJson(
            (j['components'] ?? const {}) as Map<String, dynamic>),
        warnings: ((j['warnings'] ?? const []) as List)
            .map((e) => e.toString())
            .toList(),
        strengths: ((j['strengths'] ?? const []) as List)
            .map((e) => e.toString())
            .toList(),
        exitWarnings: ((j['exit_warnings'] ?? const []) as List)
            .map((e) => e.toString())
            .toList(),
        positions: ((j['positions'] ?? const []) as List)
            .map((e) => PositionQuality.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
