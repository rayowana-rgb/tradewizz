import 'package:flutter/material.dart';

import '../cache/cache_service.dart';
import '../cache/cached_repository.dart';
import '../models/market.dart';
import '../models/subscription.dart';
import '../repositories/stock_repository.dart';
import '../services/auth_scope.dart';
import '../services/entitlements_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';
import 'premium.dart';

/// Phase 8 — premium dashboard cards: Top Opportunities, Daily Picks,
/// Multibagger Candidates, and Portfolio Health.
///
/// FREE users see blurred previews with an Upgrade button (via [LockedFeature]).
/// PRO/ELITE users see live content. Data only loads for entitled users (we
/// never call a gated endpoint we know will 402).
class PremiumDashboardSection extends StatefulWidget {
  const PremiumDashboardSection({super.key, this.repository});

  final StockRepository? repository;

  @override
  State<PremiumDashboardSection> createState() =>
      _PremiumDashboardSectionState();
}

class _PremiumDashboardSectionState extends State<PremiumDashboardSection> {
  OpportunitiesResult? _opps;
  DailyPicks? _daily;
  MultibaggerResult? _multibagger;
  PortfolioHealth? _health;
  bool _loaded = false;

  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  CachedRepository get _cached => widget.repository != null
      ? CachedRepository(widget.repository!, cache: CacheService.inMemory())
      : RepositoryScope.cachedOf(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  Entitlements get _ent => EntitlementsScope.entitlements(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) return; // logged out -> placeholder previews only
    final ent = _ent;
    // Preview pivot: when preview is on, every feature is open to everyone, so
    // we load all cards. (When preview is off, fall back to tier gating.)
    final canPro = ent.preview || ent.tier.atLeast(Tier.pro);
    final canElite = ent.preview || ent.tier.atLeast(Tier.elite);
    if (canPro) {
      _safe(() async {
        final o = await _repo.radarOpportunities(token);
        if (mounted) setState(() => _opps = o);
      });
      _safe(() async {
        final d = await _repo.radarDaily(token);
        if (mounted) setState(() => _daily = d);
      });
    }
    if (canElite) {
      _safe(() async {
        final m = await _repo.radarMultibagger(token);
        if (mounted) setState(() => _multibagger = m);
      });
      _safe(() async {
        // Phase F: portfolio health is SWR-cached (5-min TTL) so it appears
        // immediately from cache and refreshes in the background.
        final h = await _cached.portfolioHealth(token);
        if (mounted) setState(() => _health = h.value);
      });
    }
  }

  Future<void> _safe(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (_) {
      // Best-effort dashboard cards; a failure just leaves the placeholder.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('premium_dashboard_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 2, bottom: 8),
          child: Text('TradeWizz PRO Preview',
              key: Key('pro_preview_header'),
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
        _card(
          key: 'dash_card_opportunities',
          title: 'Opportunity Radar',
          description:
              'Find the strongest opportunities across global markets.',
          requiredTier: Tier.pro,
          feature: Features.opportunityRadar,
          child: _OpportunitiesCardBody(opps: _opps),
        ),
        const SizedBox(height: 12),
        _card(
          key: 'dash_card_daily',
          title: 'Daily Picks',
          description: "Today's highest conviction ideas.",
          requiredTier: Tier.pro,
          feature: Features.dailyPicks,
          child: _DailyCardBody(daily: _daily),
        ),
        const SizedBox(height: 12),
        _card(
          key: 'dash_card_health',
          title: 'Portfolio Health',
          description:
              'Analyze diversification, concentration and risk.',
          requiredTier: Tier.elite,
          feature: Features.portfolioHealth,
          child: _HealthCardBody(health: _health),
        ),
        const SizedBox(height: 12),
        _card(
          key: 'dash_card_multibagger',
          title: 'Multibagger Finder',
          description: 'Discover potential future market leaders.',
          requiredTier: Tier.elite,
          feature: Features.multibagger,
          child: _MultibaggerCardBody(result: _multibagger),
        ),
      ],
    );
  }

  Widget _card({
    required String key,
    required String title,
    required String description,
    required Tier requiredTier,
    required String feature,
    required Widget child,
  }) {
    final ent = _ent;
    // Badge text comes from the entitlements (PRO/ELITE PREVIEW) in preview
    // mode; otherwise fall back to the required-tier label.
    final badge = ent.preview
        ? ent.previewBadgeFor(feature)
        : '${requiredTier.label.toUpperCase()} PREVIEW';
    final isElite = requiredTier == Tier.elite;
    final color = isElite ? Colors.amber.shade800 : AppColors.seed;
    return Card(
      key: Key(key),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15)),
              ),
              if (badge.isNotEmpty) _tierPill(badge, color),
            ]),
            const SizedBox(height: 2),
            Text(description,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 10),
            // Fixed height keeps the preview/overlay bounds stable.
            SizedBox(
              height: 132,
              child: LockedFeature(
                requiredTier: requiredTier,
                feature: feature,
                title: title,
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tierPill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 12)),
      );
}

// --- card bodies (also used as the blurred preview placeholders) ------------

class _OpportunitiesCardBody extends StatelessWidget {
  const _OpportunitiesCardBody({this.opps});
  final OpportunitiesResult? opps;

  @override
  Widget build(BuildContext context) {
    final list = opps?.globalTop10 ?? _placeholderOpps;
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final o in list.take(4))
          _row(o.symbol, o.market.code, o.score, o.recommendation),
      ],
    );
  }
}

class _DailyCardBody extends StatelessWidget {
  const _DailyCardBody({this.daily});
  final DailyPicks? daily;

  @override
  Widget build(BuildContext context) {
    final picks = daily?.picks ?? _placeholderDaily;
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final p in picks.take(4))
          _row('${p.rank}. ${p.symbol}', p.market.code, p.score, p.signal),
      ],
    );
  }
}

class _MultibaggerCardBody extends StatelessWidget {
  const _MultibaggerCardBody({this.result});
  final MultibaggerResult? result;

  @override
  Widget build(BuildContext context) {
    final list = result?.candidates;
    if (list != null && list.isEmpty) {
      return const Center(
        child: Text('No multibagger candidates right now.',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    final rows = list ?? _placeholderMulti;
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final c in rows.take(4))
          _rowText(c.symbol, c.market.code, '${c.conviction} · ${c.riskLevel}',
              c.score),
      ],
    );
  }
}

class _HealthCardBody extends StatelessWidget {
  const _HealthCardBody({this.health});
  final PortfolioHealth? health;

  @override
  Widget build(BuildContext context) {
    final h = health;
    final score = h?.healthScore ?? 84;
    final rating = h?.rating ?? 'Good';
    final warning = (h?.warnings.isNotEmpty ?? false)
        ? h!.warnings.first
        : 'Diversify across more names to raise your score.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text('${score.toStringAsFixed(0)}/100',
              style: const TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 28)),
          const SizedBox(width: 10),
          Text(rating,
              style: const TextStyle(color: Colors.grey, fontSize: 15)),
        ]),
        const SizedBox(height: 8),
        Text(warning,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

Widget _row(String left, String market, double score, String tag) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(
          child: Text('$left · $market',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        if (tag.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(tag,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        Text(score.toStringAsFixed(0),
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ]),
    );

Widget _rowText(String left, String market, String tag, double score) =>
    _row(left, market, score, tag);

// Placeholder data so the blurred FREE preview looks like real content.
final _placeholderOpps = [
  for (final s in const [
    ['NVDA', 'US', 'Strong Buy'],
    ['BBCA', 'IDX', 'Buy'],
    ['MPMX', 'IDX', 'Buy'],
    ['AAPL', 'US', 'Buy'],
  ])
    Opportunity(
      symbol: s[0],
      market: Market.fromCode(s[1]),
      name: s[0],
      score: 90,
      signal: 'BUY',
      recommendation: s[2],
      opportunityReason: '',
      marketRegime: 'BULL',
    ),
];

final _placeholderDaily = [
  for (var i = 0; i < 4; i++)
    DailyPick(
      rank: i + 1,
      symbol: const ['NVDA', 'MPMX', 'BBCA', 'AAPL'][i],
      market: Market.fromCode(const ['US', 'IDX', 'IDX', 'US'][i]),
      name: '',
      score: 93.0 - i,
      signal: 'BUY',
      recommendation: 'Buy',
    ),
];

final _placeholderMulti = [
  for (final s in const [
    ['MPMX', 'IDX'],
    ['NVDA', 'US'],
  ])
    MultibaggerCandidate(
      symbol: s[0],
      market: Market.fromCode(s[1]),
      name: s[0],
      score: 92,
      conviction: 'HIGH',
      riskLevel: 'MEDIUM',
      reason: '',
    ),
];
