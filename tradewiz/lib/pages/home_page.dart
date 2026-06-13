import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../home/activation_scope.dart';
import '../home/todays_ideas.dart';
import '../models/market.dart';
import '../models/market_index.dart';
import '../models/market_overview.dart';
import '../models/phase2.dart';
import '../models/phase3.dart';
import '../models/simulation.dart';
import '../models/user_profile_prefs.dart';
import '../models/watchlist_item.dart';
import '../repositories/stock_repository.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../services/user_prefs_scope.dart';
import '../services/watchlist_scope.dart';
import '../snapshot/snapshot_models.dart';
import '../snapshot/snapshot_repository.dart';
import '../widgets/global_rotation.dart';
import '../theme_tradewizz.dart';
import '../widgets/ds/ds.dart';
import 'account_page.dart';
import 'ai_analysis_page.dart';

/// Phase B/D/E — the redesigned, personalized AI Home screen.
///
/// Hierarchy (one clear primary action; ~50% less visible complexity than the
/// old dashboard):
///   1. AI Hero card    — greeting + Today's Best Idea + confidence + reason.
///   2. Morning Brief   — max 3 bullets, ~15s read.
///   3. Portfolio       — value + daily/weekly P&L + best/worst.
///   4. Watchlist       — compact highlights + one AI alert.
///   5. Today's Ideas   — the merged, ranked idea feed.
///
/// It renders instantly from the Hive snapshot (offline-first) and refreshes in
/// the background. The underlying engines/APIs are unchanged.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.market,
    this.repository,
    this.snapshot,
  });

  final Market market;
  final StockRepository? repository;
  final SnapshotRepository? snapshot;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  SnapshotRepository? _snap;
  StockRepository? _repo;
  DashboardSnapshot? _dashboard;
  SimAccount? _account;
  List<SimPosition> _positions = const [];
  bool _briefCounted = false;
  bool _viewedCounted = false;
  // Phase C/D/E: index movement, market activity, Fear/Greed condition.
  MarketIndex? _index;
  MarketOverview? _overview;
  MarketCondition _condition = MarketCondition.unknown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repo ??= widget.repository ?? RepositoryScope.of(context);
    _snap ??= widget.snapshot ?? RepositoryScope.snapshotOf(context);
    if (!_viewedCounted) {
      _viewedCounted = true;
      final metrics = ActivationScope.maybeOf(context);
      WidgetsBinding.instance
          .addPostFrameCallback((_) => metrics?.homeViewed());
    }
    _load();
  }

  @override
  void didUpdateWidget(covariant HomePage old) {
    super.didUpdateWidget(old);
    if (old.market != widget.market) {
      // Reset market-scoped panels so a stale index/condition from the prior
      // market never lingers while the new one loads.
      setState(() {
        _index = null;
        _overview = null;
        _condition = MarketCondition.unknown;
      });
      _load();
    }
  }

  Future<void> _load() async {
    // 1) Instant render from Hive.
    final peek = _snap?.peekDashboard(widget.market);
    if (peek != null && mounted) setState(() => _dashboard = peek);

    final token = AuthScope.of(context).token;
    if (token == null) return;
    // Capture the metrics object before any async gap.
    final metrics = ActivationScope.maybeOf(context);

    // 2) Background refresh (SWR) — never blocks the UI.
    try {
      _snap?.dashboardSwr(token, widget.market).listen((c) {
        if (mounted) setState(() => _dashboard = c.value);
        if (!_briefCounted && c.value.morningBrief != null) {
          _briefCounted = true;
          metrics?.morningBriefOpened();
        }
      });
    } catch (_) {/* offline-first */}

    // 3) Portfolio (best-effort).
    try {
      final p = await _repo?.simPortfolio(token);
      if (p != null && mounted) {
        setState(() {
          _account = p.account;
          _positions = p.positions;
        });
      }
    } catch (_) {/* keep what we have */}

    // 4) Index movement + market activity + Fear/Greed (all best-effort and
    //    independent: any failure leaves the rest of Home intact).
    _loadMarketSnapshot();
  }

  Future<void> _loadMarketSnapshot() async {
    final repo = _repo;
    if (repo == null) return;
    final market = widget.market;
    try {
      final idx = await repo.marketIndex(market);
      if (mounted && idx != null) setState(() => _index = idx);
    } catch (_) {/* index card shows unavailable */}
    try {
      final ov = await repo.marketOverview(market);
      if (mounted) setState(() => _overview = ov);
    } catch (_) {/* value traded falls back to Today's Ideas aggregate */}
    try {
      final cond = await repo.marketCondition(market);
      if (mounted) setState(() => _condition = cond);
    } catch (_) {/* condition stays Unknown */}
  }

  UserPrefs get _prefs =>
      UserPrefsScope.maybeOf(context)?.prefs ?? const UserPrefs();

  TodaysIdeas get _ideas {
    final d = _dashboard;
    if (d == null) return const TodaysIdeas.empty();
    return TodaysIdeas.fromSnapshot(d, prefs: _prefs);
  }

  @override
  Widget build(BuildContext context) {
    final ideas = _ideas;
    final brief = _dashboard?.morningBrief;
    // Keep content clear of the floating nav bar at the bottom.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return TWScaffoldBackground(
      child: RefreshIndicator(
        color: TWColors.accentBright,
        backgroundColor: TWColors.bgElevated,
        onRefresh: _load,
        child: ListView(
          key: const Key('home_list'),
          padding: EdgeInsets.fromLTRB(
              TWSpace.xl, TWSpace.lg, TWSpace.xl, TWSpace.xxxl + bottomInset),
          children: [
            _HeroCard(
              greeting: _greeting(),
              idea: ideas.ideas.isNotEmpty ? ideas.ideas.first : null,
              fallback: brief?.topOpportunity,
              onView: _openAnalysis,
            ),
            const SizedBox(height: TWSpace.md),
            // Market Pulse card first.
            _MarketPulseCard(
              market: widget.market,
              index: _index,
              overview: _overview,
              condition: _condition,
              ideas: ideas,
            ),
            const SizedBox(height: TWSpace.lg),
            // Morning Brief — inline section (no card) below Market Pulse.
            _BriefCard(brief: brief, rotation: _dashboard?.rotation),
            const SizedBox(height: TWSpace.md),
            _PortfolioCard(
              account: _account,
              positions: _positions,
              onOpenPortfolio: _openPortfolio,
            ),
            const SizedBox(height: TWSpace.xl),
            // Watchlist as a light inline strip (no card) — reduces card count
            // and varies the rhythm before the ranked ideas list.
            _WatchlistStrip(market: widget.market),
            const SizedBox(height: TWSpace.lg),
            _IdeasSection(
              ideas: ideas,
              rotation: _dashboard?.rotation,
              onTap: _openIdea,
              onTapIndex: _openIndex,
            ),
          ],
        ),
      ),
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    final part = h < 12
        ? 'Good Morning'
        : (h < 18 ? 'Good Afternoon' : 'Good Evening');
    final name = _prefs.displayName;
    return name.isEmpty ? part : '$part $name';
  }

  void _openIdea(TradeIdea idea) {
    ActivationScope.maybeOf(context)?.ideaTapped(idea.symbol);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AnalysisDetailPage(
        symbol: idea.symbol,
        market: idea.market,
        repository: _repo,
      ),
    ));
  }

  // Tapping the best-index card opens the Global Rotation detail so the user
  // can see why this market ranks first and how the others compare.
  void _openIndex(MarketRotation entry) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Theme(
        data: buildTradeWizzTheme(),
        child: GlobalRotationDetailPage(
          repository: _repo,
          data: _dashboard?.rotation,
        ),
      ),
    ));
  }

  void _openPortfolio() {
    // AccountPage is designed to live INSIDE the bottom-nav shell (which
    // supplies the Theme + Scaffold + SafeArea). Pushing it bare gave it no
    // width constraints and no Material ancestor -> RenderFlex overflow (the
    // yellow/black stripes) and Chip "no Material" errors. Wrap it the same
    // way AnalysisDetailPage does, and add an AppBar so there is a back button.
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Theme(
        data: buildTradeWizzTheme(),
        child: Scaffold(
          backgroundColor: TWColors.bgBase,
          appBar: AppBar(
            backgroundColor: TWColors.bgBase,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            title: Text('Account', style: TWType.title3),
          ),
          body: SafeArea(
            bottom: false,
            child: AccountPage(repository: _repo),
          ),
        ),
      ),
    ));
  }

  void _openAnalysis() {
    final idea = _ideas.ideas.isNotEmpty ? _ideas.ideas.first : null;
    final brief = _dashboard?.morningBrief?.topOpportunity;
    final symbol = idea?.symbol ?? brief?.symbol;
    final market = idea?.market ?? brief?.market ?? widget.market;
    if (symbol == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AnalysisDetailPage(
        symbol: symbol,
        market: market,
        repository: _repo,
      ),
    ));
  }
}

// =========================================================================
// 1) AI Hero card
// =========================================================================
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.greeting,
    required this.idea,
    required this.fallback,
    required this.onView,
  });
  final String greeting;
  final TradeIdea? idea;
  final BriefPick? fallback;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final symbol = idea?.symbol ?? fallback?.symbol;
    final name = idea?.name ?? fallback?.name ?? '';
    final signal = idea?.signal ?? fallback?.signal ?? 'WATCH';
    final score = idea?.score ?? fallback?.score ?? 0;
    final reason = idea?.reason ??
        fallback?.reason ??
        'Your personalized idea will appear here after the next market open.';
    final hasIdea = symbol != null;

    final tags = _heroTags(reason, signal);
    return Container(
      key: const Key('home_hero'),
      width: double.infinity,
      padding: const EdgeInsets.all(TWSpace.xl),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(TWRadius.cardLg),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [TWColors.bgElevated, TWColors.bgRaised],
        ),
        border: Border.all(color: TWColors.hairlineTop, width: 1),
        boxShadow: const [...TWShadow.ambient, ...TWShadow.accentGlow],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const TWAiOrb(size: 36),
              const SizedBox(width: TWSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(greeting,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TWType.bodySm.copyWith(
                            color: TWColors.textSecondary,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 1),
                    Text("Today's Best Idea",
                        style: TWType.overline.copyWith(
                            color: TWColors.accentBright,
                            letterSpacing: 0.6)),
                  ],
                ),
              ),
            ],
          ),
          if (hasIdea) ...[
            // Non-null ticker inside the hasIdea branch (hasIdea => symbol!=null).
            const SizedBox(height: TWSpace.lg),
            // Identity line: full company name (truncated with "..." only when
            // it does not fit) + signal chip. Ticker shown as a subtitle.
            // The Score pill was removed; confidence lives on the tags row.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isNotEmpty ? name : symbol,
                        key: const Key('home_hero_name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TWType.title1.copyWith(
                            fontWeight: FontWeight.w800, fontSize: 26),
                      ),
                      if (name.isNotEmpty)
                        Text(symbol,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TWType.label.copyWith(
                                color: TWColors.textSecondary,
                                fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                const SizedBox(width: TWSpace.md),
                TWSignalPill(signal: signal),
              ],
            ),
            const SizedBox(height: TWSpace.md),
            // Tags row (Momentum / Strong Liquidity / ...) with the Confidence
            // indicator moved here from the top-right of the card.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: tags.isNotEmpty
                      ? Wrap(
                          key: const Key('home_hero_tags'),
                          spacing: TWSpace.sm,
                          runSpacing: TWSpace.sm,
                          children: [
                            for (final t in tags) TWTagChip(label: t)
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(width: TWSpace.md),
                _Confidence(score: score),
              ],
            ),
            const SizedBox(height: TWSpace.md),
            Text(reason,
                key: const Key('home_hero_reason'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TWType.bodySm.copyWith(
                    color: TWColors.textPrimary, height: 1.35)),
            const SizedBox(height: TWSpace.lg),
            TWGradientButton(
              key: const Key('home_hero_cta'),
              label: 'View Analysis',
              icon: Icons.auto_graph_rounded,
              onPressed: onView,
            ),
            const SizedBox(height: TWSpace.sm),
            Text('AI research \u00b7 educational only, not financial advice.',
                style: TWType.caption),
          ] else ...[
            const SizedBox(height: TWSpace.md),
            Text(reason,
                style: TWType.body.copyWith(color: TWColors.textSecondary)),
          ],
        ],
      ),
    );
  }

  /// Derive up to two short, signal-aware tags from the idea's reason text so
  /// the compact hero conveys conviction without any engine change.
  List<String> _heroTags(String reason, String signal) {
    final r = reason.toLowerCase();
    final out = <String>[];
    void add(String t) {
      if (out.length < 2 && !out.contains(t)) out.add(t);
    }
    if (r.contains('cmf') || r.contains('money flow')) add('Strong CMF');
    if (r.contains('obv') || r.contains('volume')) add('Strong OBV');
    if (r.contains('accumulation')) add('Accumulation');
    if (r.contains('momentum') || r.contains('relative strength')) {
      add('Momentum');
    }
    if (r.contains('liquid')) add('Strong Liquidity');
    if (r.contains('breakout')) add('Breakout');
    if (out.isEmpty) {
      final s = signal.toUpperCase();
      if (s.contains('BUY')) add('Bullish setup');
    }
    return out;
  }
}

class _Confidence extends StatelessWidget {
  const _Confidence({required this.score});
  final double score;
  @override
  Widget build(BuildContext context) {
    final color = TWColors.confidence(score);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('Confidence', style: TWType.overline.copyWith(fontSize: 12)),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7, height: 7,
              margin: const EdgeInsets.only(right: 6, bottom: 3),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            // Bare number kept as its own Text so tests can assert on it.
            Text(score.toStringAsFixed(0),
                style: TWType.tabular(TWType.title2).copyWith(color: color)),
            Text('%',
                style: TWType.label.copyWith(color: TWColors.textTertiary)),
          ],
        ),
      ],
    );
  }
}

// =========================================================================
// 2) Market Today — merged Morning Brief (max 3 bullets) + Market Pulse strip.
//    Two related panels share one card, split by a hairline, so Home shows
//    fewer surfaces while keeping every test key intact.
// =========================================================================
// =========================================================================
// 2a) Morning Brief — inline section (no card) shown below Market Pulse.
// =========================================================================
class _BriefCard extends StatelessWidget {
  const _BriefCard({required this.brief, this.rotation});

  final MorningBrief? brief;
  final GlobalRotation? rotation;

  @override
  Widget build(BuildContext context) {
    final insights = _insights();
    return TWFloatingCard(
      key: const Key('home_brief'),
      gradient: TWColors.briefGradient,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const TWAiOrb(size: 28, glow: false),
              const SizedBox(width: TWSpace.sm),
              Text('Morning Brief', style: TWType.title3),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: TWSpace.md, vertical: 4),
                decoration: BoxDecoration(
                  color: TWColors.bgElevated,
                  borderRadius: TWRadius.rChip,
                ),
                child: Text('15s read', style: TWType.caption),
              ),
            ],
          ),
          const SizedBox(height: TWSpace.lg),
          if (insights.isEmpty)
            Text('Your brief is being prepared.',
                style: TWType.bodySm.copyWith(color: TWColors.textTertiary))
          else
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < insights.length; i++) ...[
                    if (i > 0)
                      Container(
                        width: 1,
                        margin: const EdgeInsets.symmetric(
                            horizontal: TWSpace.md),
                        color: TWColors.hairlineTop,
                      ),
                    Expanded(
                      child: _InsightColumn(
                          index: i + 1, insight: insights[i]),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: TWSpace.lg),
          Container(height: 1, color: TWColors.hairlineTop),
          const SizedBox(height: TWSpace.md),
          Text('Generated by Wizz · not financial advice',
              style:
                  TWType.caption.copyWith(color: TWColors.textTertiary)),
        ],
      ),
    );
  }

  /// Build up to three structured insight blocks from the existing brief
  /// fields. Presentation only — no new data, no recomputation.
  List<_BriefInsight> _insights() {
    final b = brief;
    if (b == null) return const [];
    final out = <_BriefInsight>[];

    // 0) Best Index — the top market to be in today (Global Rotation). Shown
    // FIRST so "where to be" leads the brief, mirroring Today's Ideas.
    final best = rotation?.bestEntry;
    if (best != null) {
      out.add(_BriefInsight(
        title: 'Best Index',
        ticker: '${best.market.flag} ${best.market.name}',
        body: best.recommendation.isNotEmpty
            ? '${best.recommendation[0].toUpperCase()}'
                '${best.recommendation.substring(1).toLowerCase()} today'
            : 'Top-ranked market today',
        tickerStyle: _TickerStyle.heroSector,
      ));
    }

    // 1) Market Outlook — headline + "Top opportunity: TICKER (Score N)".
    final o = b.topOpportunity;
    out.add(_BriefInsight(
      title: 'Market Outlook',
      body: b.headline.isNotEmpty
          ? b.headline
          : '${b.market.code} session overview.',
      opportunityLabel: o != null ? 'Top opportunity:' : null,
      ticker: o?.symbol,
      tickerMeta:
          o != null ? '(Score ${o.score.toStringAsFixed(0)})' : null,
      tickerStyle: _TickerStyle.inlineWithBody,
    ));

    // 2) Strongest Signal — big ticker + score pill + bullet list.
    if (o != null) {
      out.add(_BriefInsight(
        title: 'Strongest Signal',
        ticker: o.symbol,
        scorePill: 'Score ${o.score.toStringAsFixed(0)}',
        bullets: _signalChips(o),
        tickerStyle: _TickerStyle.heroTicker,
      ));
    }

    // 3) Sector Strength.
    if (b.strongestSector.isNotEmpty) {
      out.add(_BriefInsight(
        title: 'Sector Strength',
        ticker: b.strongestSector,
        body: 'Leading sector today',
        tickerStyle: _TickerStyle.heroSector,
      ));
    }

    return out.take(3).toList();
  }

  /// Derive up to three short qualitative chips from the pick's reason/signal.
  List<String> _signalChips(BriefPick o) {
    final r = o.reason.toLowerCase();
    final out = <String>[];
    void add(String t) {
      if (out.length < 3 && !out.contains(t)) out.add(t);
    }
    if (r.contains('relative strength') || r.contains('leading')) {
      add('Leading relative strength');
    }
    if (r.contains('liquid') || r.contains('volume')) add('Strong liquidity');
    if (r.contains('bull') || o.signal.toUpperCase() == 'BUY') {
      add('Bull regime');
    }
    if (r.contains('accumulation')) add('Accumulation');
    if (r.contains('breakout')) add('Breakout structure');
    if (out.isEmpty) {
      add(o.reason.isEmpty ? o.signal : o.reason);
    }
    return out;
  }

}

enum _TickerStyle { inlineWithBody, heroTicker, heroSector }

/// Immutable view-model for one Morning Brief insight column (presentation
/// only — assembled from existing MorningBrief fields).
class _BriefInsight {
  const _BriefInsight({
    required this.title,
    required this.tickerStyle,
    this.body,
    this.ticker,
    this.tickerMeta,
    this.opportunityLabel,
    this.scorePill,
    this.bullets = const [],
  });
  final String title;
  final _TickerStyle tickerStyle;
  final String? body;
  final String? ticker;
  final String? tickerMeta;
  final String? opportunityLabel;
  final String? scorePill;
  final List<String> bullets;
}

/// A single briefing column: numbered header (circle + title) then content,
/// laid out side-by-side in the Morning Brief card.
class _InsightColumn extends StatelessWidget {
  const _InsightColumn({required this.index, required this.insight});
  final int index;
  final _BriefInsight insight;

  @override
  Widget build(BuildContext context) {
    final i = insight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Numbered header: accent circle + section title.
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: TWColors.accent.withValues(alpha: 0.18),
                shape: BoxShape.circle,
                border: Border.all(
                    color: TWColors.accent.withValues(alpha: 0.45),
                    width: 1),
              ),
              child: Text('$index',
                  style: TWType.tabular(TWType.caption).copyWith(
                      color: TWColors.accentBright,
                      fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(i.title.toUpperCase(),
                  maxLines: 2,
                  style: TWType.bodySm.copyWith(
                      color: TWColors.accentBright,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.1)),
            ),
          ],
        ),
        const SizedBox(height: TWSpace.sm),
        ..._content(i),
      ],
    );
  }

  List<Widget> _content(_BriefInsight i) {
    switch (i.tickerStyle) {
      case _TickerStyle.inlineWithBody:
        return [
          if (i.body != null)
            Text(i.body!,
                style: TWType.bodySm.copyWith(
                    color: TWColors.textPrimary,
                    fontSize: 12,
                    height: 1.3)),
          if (i.opportunityLabel != null) ...[
            const SizedBox(height: 4),
            Text(i.opportunityLabel!,
                style: TWType.bodySm.copyWith(
                    color: TWColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 2),
            RichText(
              text: TextSpan(children: [
                TextSpan(
                    text: i.ticker ?? '',
                    style: TWType.bodySm.copyWith(
                        color: TWColors.accentBright,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                if (i.tickerMeta != null)
                  TextSpan(
                      text: ' ${i.tickerMeta}',
                      style: TWType.bodySm.copyWith(
                          color: TWColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
              ]),
            ),
          ],
        ];
      case _TickerStyle.heroTicker:
        return [
          Text(i.ticker ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TWType.title3.copyWith(
                  color: TWColors.accentBright,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          if (i.scorePill != null) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: TWSpace.sm, vertical: 3),
              decoration: BoxDecoration(
                color: TWColors.accent.withValues(alpha: 0.16),
                borderRadius: TWRadius.rChip,
              ),
              child: Text(i.scorePill!,
                  style: TWType.tabular(TWType.caption).copyWith(
                      color: TWColors.accentBright,
                      fontWeight: FontWeight.w700)),
            ),
          ],
          if (i.bullets.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final b in i.bullets)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 6),
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: const BoxDecoration(
                            color: TWColors.textTertiary,
                            shape: BoxShape.circle),
                      ),
                    ),
                    Expanded(
                      child: Text(b,
                          style: TWType.bodySm.copyWith(
                              color: TWColors.textSecondary,
                              fontSize: 12,
                              height: 1.3)),
                    ),
                  ],
                ),
              ),
          ],
        ];
      case _TickerStyle.heroSector:
        return [
          Text(i.ticker ?? '',
              maxLines: 2,
              style: TWType.bodySm.copyWith(
                  color: TWColors.accentBright,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  height: 1.2)),
          if (i.body != null) ...[
            const SizedBox(height: 4),
            Text(i.body!,
                style: TWType.bodySm.copyWith(
                    color: TWColors.textPrimary, fontSize: 12)),
          ],
        ];
    }
  }
}

// =========================================================================
// 2b) Market Pulse — index move + market activity + Fear/Greed, its own card.
// =========================================================================
class _MarketPulseCard extends StatelessWidget {
  const _MarketPulseCard({
    required this.market,
    required this.index,
    required this.overview,
    required this.condition,
    required this.ideas,
  });

  final Market market;
  final MarketIndex? index;
  final MarketOverview? overview;
  final MarketCondition condition;
  final TodaysIdeas ideas;

  @override
  Widget build(BuildContext context) {
    return TWFloatingCard(
      child: _pulseSection(context),
    );
  }

  // ---- Market Pulse ----
  Widget _pulseSection(BuildContext context) {
    final idx = index;
    final exchangeValue = overview?.totalValueTraded;
    final valueLabel =
        exchangeValue != null ? 'Value Traded Today' : 'Top Ideas Value Traded';
    final valueText = exchangeValue != null
        ? _compactMoney(market, exchangeValue)
        : (ideas.ideas.isEmpty ? 'n/a' : '${ideas.ideas.length} ideas');

    return Column(
      key: const Key('home_index_card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const TWEyebrow('Market Pulse'),
                  const SizedBox(height: 3),
                  Text(
                    idx?.name ?? '${market.code} Index',
                    key: const Key('home_index_name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TWType.title3.copyWith(fontSize: 15),
                  ),
                ],
              ),
            ),
            const SizedBox(width: TWSpace.sm),
            _ConditionBadge(condition: condition),
          ],
        ),
        const SizedBox(height: TWSpace.lg),
        // Price + change, grouped on a baseline-aligned line of their own.
        if (idx != null && idx.hasData)
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                idx.price!.toStringAsFixed(2),
                key: const Key('home_index_price'),
                style: TWType.tabular(TWType.title2)
                    .copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: TWSpace.md),
              Text(
                '${idx.isUp ? '+' : ''}'
                '${(idx.change ?? 0).toStringAsFixed(2)} '
                '(${idx.isUp ? '+' : ''}'
                '${(idx.changePercent ?? 0).toStringAsFixed(2)}%)',
                key: const Key('home_index_change'),
                style: TWType.tabular(TWType.label).copyWith(
                  color: idx.isUp ? TWColors.up : TWColors.down,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          )
        else
          Text(
            idx == null ? 'Index data loading\u2026' : 'Index data unavailable',
            key: const Key('home_index_unavailable'),
            style: TWType.bodySm.copyWith(color: TWColors.textTertiary),
          ),
        const SizedBox(height: TWSpace.lg),
        // Stats grid — same two-column rhythm in every state.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _MiniStat(
                label: valueLabel,
                value: valueText,
                valueKey: const Key('home_value_traded'),
              ),
            ),
            Expanded(
              child: _MiniStat(
                  label: 'Status', value: idx?.status ?? '\u2014'),
            ),
          ],
        ),
        if (condition.isKnown && condition.reason.isNotEmpty) ...[
          const SizedBox(height: TWSpace.md),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(TWSpace.sm),
            decoration: BoxDecoration(
              color: TWColors.bgElevated,
              borderRadius: TWRadius.rChip,
            ),
            child: Text(
              condition.reason,
              key: const Key('home_condition_reason'),
              style: TWType.caption.copyWith(height: 1.3),
            ),
          ),
        ],
      ],
    );
  }
}

// =========================================================================
// 2c) Helpers + badges for the Market Pulse section (above) — currency
//     formatting, Fear/Greed colors, condition badge and mini-stats.
// =========================================================================
String _currencySymbol(Market m) => switch (m.currency) {
      'USD' => '\$',
      'IDR' => 'Rp',
      'JPY' => '¥',
      'INR' => '₹',
      'VND' => '₫',
      'SGD' => 'S\$',
      'HKD' => 'HK\$',
      'KRW' => '₩',
      _ => '',
    };

String _compactMoney(Market m, double? v) {
  if (v == null) return 'n/a';
  final cur = _currencySymbol(m);
  final a = v.abs();
  String body;
  if (a >= 1e12) {
    body = '${(v / 1e12).toStringAsFixed(1)}T';
  } else if (a >= 1e9) {
    body = '${(v / 1e9).toStringAsFixed(1)}B';
  } else if (a >= 1e6) {
    body = '${(v / 1e6).toStringAsFixed(1)}M';
  } else if (a >= 1e3) {
    body = '${(v / 1e3).toStringAsFixed(1)}K';
  } else {
    body = v.toStringAsFixed(0);
  }
  return '$cur$body';
}

Color _conditionColor(String condition) => switch (condition) {
      'EXTREME_FEAR' => TWColors.down,
      'FEAR' => TWColors.warn,
      'GREED' => TWColors.up,
      'EXTREME_GREED' => const Color(0xFF1B8E3D),
      _ => TWColors.neutral,
    };


class _ConditionBadge extends StatelessWidget {
  const _ConditionBadge({required this.condition});
  final MarketCondition condition;

  @override
  Widget build(BuildContext context) {
    final color = _conditionColor(condition.condition);
    return Container(
      key: const Key('home_condition_badge'),
      padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.md, vertical: TWSpace.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: TWRadius.rChip,
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            condition.label,
            style: TWType.label.copyWith(color: color),
          ),
          if (condition.isKnown)
            Text(
              '${condition.score}/100',
              style: TWType.tabular(TWType.caption).copyWith(color: color),
            ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    this.valueKey,
  });
  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TWType.caption),
        const SizedBox(height: 2),
        Text(value,
            key: valueKey,
            style: TWType.tabular(TWType.label)
                .copyWith(color: TWColors.textPrimary)),
      ],
    );
  }
}

// =========================================================================
// 3) Portfolio (value + P&L + best/worst)
// =========================================================================
class _PortfolioCard extends StatelessWidget {
  const _PortfolioCard({
    required this.account,
    required this.positions,
    required this.onOpenPortfolio,
  });
  final SimAccount? account;
  final List<SimPosition> positions;
  final VoidCallback onOpenPortfolio;

  @override
  Widget build(BuildContext context) {
    final a = account;
    // Phase 11: premium "wealth dashboard" hero. Presentation only — every
    // number below comes straight from the existing SimAccount / SimPosition
    // data (no new API, no recalculation of the portfolio engine).
    if (a == null) {
      return TWFloatingCard(
        key: const Key('home_portfolio'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TWEyebrow('Simulated Portfolio'),
            const SizedBox(height: TWSpace.sm),
            Text('My Portfolio', style: TWType.title3),
            const SizedBox(height: TWSpace.sm),
            Text('Start a simulated portfolio to track P&L here.',
                style:
                    TWType.bodySm.copyWith(color: TWColors.textTertiary)),
          ],
        ),
      );
    }

    final totalPnl = a.realizedPnl + a.unrealizedPnl;
    final basis = a.equity - totalPnl;
    final totalPct = basis.abs() > 0 ? totalPnl / basis * 100 : 0.0;
    final todayPnl = a.unrealizedPnl;
    final todayPct = a.marketValue.abs() > 0
        ? todayPnl / (a.marketValue - todayPnl).clamp(1, double.infinity) * 100
        : 0.0;
    final totalUp = totalPnl >= 0;

    final winner = _extreme(highest: true);
    final largest = _largest();

    return Container(
      key: const Key('home_portfolio'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(TWRadius.premium),
        border: Border.all(color: TWColors.hairlineTop, width: 1),
        boxShadow: TWShadow.premium,
      ),
      child: Container(
        decoration: const BoxDecoration(
          gradient: TWColors.portfolioGradient,
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header — icon + title + positions badge.
            Row(
              children: [
                const Text('My Portfolio',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
                const Spacer(),
                _Pill(text: '${positions.length} '
                    '${positions.length == 1 ? 'Position' : 'Positions'}'),
              ],
            ),
            const SizedBox(height: 18),
            // Value block + Today's P/L card side-by-side.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Portfolio Value',
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(_money(a.equity, a.currency),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                              fontFeatures: [FontFeature.tabularFigures()],
                            )),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                              totalUp
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              color: TWColors.up,
                              size: 15),
                          const SizedBox(width: 2),
                          Flexible(
                            child: Text(
                              '${totalUp ? '+' : '-'}'
                              '${_money(totalPnl.abs(), a.currency)}  '
                              '(${totalUp ? '+' : ''}'
                              '${totalPct.toStringAsFixed(2)}%)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: TWColors.up,
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child:
                      _todayCard(todayPnl, todayPct, a.currency, positions),
                ),
              ],
            ),
            if (winner != null || largest != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  if (winner != null)
                    Expanded(
                      child: _PortfolioMetricCard(
                        label: 'Top Winner',
                        symbol: winner.symbol,
                        value: _pct(winner),
                        up: _ret(winner) >= 0,
                        chart: _MetricChart.sparkline,
                      ),
                    ),
                  if (winner != null && largest != null)
                    const SizedBox(width: 12),
                  if (largest != null)
                    Expanded(
                      child: _PortfolioMetricCard(
                        label: 'Largest Position',
                        symbol: largest.symbol,
                        value: '${_weight(largest, a).toStringAsFixed(0)}%',
                        up: null,
                        chart: _MetricChart.donut,
                        donutPct: _weight(largest, a),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            GestureDetector(
              onTap: onOpenPortfolio,
              child: Container(
                key: const Key('home_portfolio_cta'),
                width: double.infinity,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: TWColors.accentGradient,
                  borderRadius: BorderRadius.circular(TWRadius.button),
                  boxShadow: TWShadow.accentGlow,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Open Portfolio',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 15)),
                    SizedBox(width: 6),
                    Icon(Icons.chevron_right,
                        color: Colors.white, size: 20),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('Simulation only \u00b7 not a brokerage account.',
                style: TWType.caption.copyWith(color: Colors.white60)),
          ],
        ),
      ),
    );
  }

  Widget _todayCard(
      double v, double pct, String currency, List<SimPosition> ps) {
    final up = v >= 0;
    final upColor = up ? TWColors.up : TWColors.down;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TWRadius.card),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Today's P/L",
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${up ? '+' : '-'}${_money(v.abs(), currency)}',
                    style: TextStyle(
                      color: upColor,
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      height: 1.0,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '(${up ? '+' : ''}${pct.toStringAsFixed(2)}%)',
                  style: TextStyle(
                    color: upColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 52,
            height: 42,
            child:
                TWSparkline(points: _trendPoints(ps), up: up, height: 42),
          ),
        ],
      ),
    );
  }

  /// A small, deterministic trend series derived from the existing positions'
  /// returns — presentation only (no new data, no recomputation of P&L).
  List<double> _trendPoints(List<SimPosition> ps) {
    if (ps.isEmpty) return const [0, 0.3, 0.2, 0.6, 0.5, 0.9, 1.0];
    final rets = ps.map(_ret).toList()..sort();
    var acc = 0.0;
    final out = <double>[0];
    for (final r in rets) {
      acc += r;
      out.add(acc);
    }
    return out;
  }

  SimPosition? _extreme({required bool highest}) {
    if (positions.isEmpty) return null;
    final sorted = [...positions]
      ..sort((x, y) => _ret(x).compareTo(_ret(y)));
    return highest ? sorted.last : sorted.first;
  }

  SimPosition? _largest() {
    if (positions.isEmpty) return null;
    final sorted = [...positions]
      ..sort((x, y) => x.marketValue.compareTo(y.marketValue));
    return sorted.last;
  }

  double _weight(SimPosition p, SimAccount a) {
    final denom = a.marketValue.abs() > 0 ? a.marketValue : a.equity;
    if (denom.abs() == 0) return 0;
    return (p.marketValue / denom * 100).clamp(0, 100).toDouble();
  }

  double _ret(SimPosition p) {
    if (p.averageCost == 0) return 0;
    return (p.lastPrice - p.averageCost) / p.averageCost * 100;
  }

  String _pct(SimPosition p) {
    final r = _ret(p);
    return '${r >= 0 ? '+' : ''}${r.toStringAsFixed(1)}%';
  }

  // Grouped, tabular-friendly money string: "Rp 157,250,000".
  String _money(double v, String currency) {
    final neg = v < 0;
    final abs = v.abs();
    final whole = abs >= 1000 ? abs.round().toString() : null;
    final body = whole != null
        ? _group(whole)
        : abs.toStringAsFixed(2);
    return '${neg ? '-' : ''}$currency $body';
  }

  String _group(String digits) {
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return buf.toString();
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 12)),
    );
  }
}

/// An inset metric card inside the portfolio hero (Top Winner / Largest).
enum _MetricChart { none, sparkline, donut }

class _PortfolioMetricCard extends StatelessWidget {
  const _PortfolioMetricCard({
    required this.label,
    required this.symbol,
    required this.value,
    required this.up,
    this.chart = _MetricChart.none,
    this.donutPct = 0,
  });
  final String label;
  final String symbol;
  final String value;
  final bool? up; // null = neutral (no arrow / white text)
  final _MetricChart chart;
  final double donutPct;

  @override
  Widget build(BuildContext context) {
    final valueColor = up == null
        ? Colors.white
        : (up! ? TWColors.up : TWColors.down);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TWRadius.card),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(symbol,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15)),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (up != null) ...[
                      Icon(up! ? Icons.arrow_upward : Icons.arrow_downward,
                          color: valueColor, size: 12),
                      const SizedBox(width: 1),
                    ],
                    Flexible(
                      child: Text(value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: valueColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (chart == _MetricChart.sparkline) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 44,
              height: 38,
              child: TWSparkline(
                  points: const [0, 0.2, 0.15, 0.45, 0.4, 0.7, 0.65, 1.0],
                  up: up ?? true,
                  height: 38),
            ),
          ] else if (chart == _MetricChart.donut) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 42,
              height: 42,
              child: CustomPaint(
                painter: _DonutPainter(
                    progress: (donutPct / 100).clamp(0.0, 1.0)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Thin progress donut used for the "Largest Position" weight.
class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const stroke = 6.0;
    final radius = (size.shortestSide - stroke) / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.18);
    canvas.drawCircle(center, radius, track);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: 3 * math.pi / 2,
        colors: const [TWColors.accent, TWColors.accentBright],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.progress != progress;
}

// =========================================================================
// 4) Watchlist insights — a light inline strip (no card) so Home breathes:
//    section header + symbol chips + one AI alert, sitting on the page
//    background instead of yet another floating surface.
// =========================================================================
class _WatchlistStrip extends StatelessWidget {
  const _WatchlistStrip({required this.market});
  final Market market;

  @override
  Widget build(BuildContext context) {
    final store = WatchlistScope.maybeOf(context);
    final items = store?.forMarket(market) ?? const <WatchlistItem>[];
    return Column(
      key: const Key('home_watchlist'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: TWSpace.md),
          child: TWSectionHeader(
              title: 'Your Watchlist', eyebrow: 'Watchlist Insights'),
        ),
        if (items.isEmpty)
          Text('Add symbols to see daily highlights.',
              style: TWType.bodySm.copyWith(color: TWColors.textTertiary))
        else ...[
          Wrap(
            spacing: TWSpace.sm,
            runSpacing: TWSpace.sm,
            children: [
              for (final i in items.take(6)) TWTagChip(label: i.symbol),
            ],
          ),
          const SizedBox(height: TWSpace.md),
          Row(
            children: [
              const Icon(Icons.bolt_rounded, size: 16, color: TWColors.warn),
              const SizedBox(width: TWSpace.xs),
              Expanded(
                child: Text(
                  'AI Alert: ${items.first.symbol} approaching a key level.',
                  style:
                      TWType.bodySm.copyWith(color: TWColors.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// =========================================================================
// 5) Today's Ideas
// =========================================================================
class _IdeasSection extends StatelessWidget {
  const _IdeasSection({
    required this.ideas,
    required this.onTap,
    this.rotation,
    this.onTapIndex,
  });
  final TodaysIdeas ideas;
  final GlobalRotation? rotation;
  final ValueChanged<TradeIdea> onTap;
  final ValueChanged<MarketRotation>? onTapIndex;

  @override
  Widget build(BuildContext context) {
    final bestIndex = rotation?.bestEntry;
    return Column(
      key: const Key('home_ideas'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: TWSpace.xs, bottom: TWSpace.md),
          child: TWSectionHeader(title: "Today's Ideas", eyebrow: 'Ranked'),
        ),
        // Best index first (Global Rotation), then the best stocks: "where to
        // be" before "what to buy".
        if (bestIndex != null) ...[
          _BestIndexCard(
            entry: bestIndex,
            onTap: onTapIndex == null ? null : () => onTapIndex!(bestIndex),
          ),
          const SizedBox(height: TWSpace.md),
        ],
        if (ideas.isEmpty)
          TWEmptyState(
            title: 'No ideas yet',
            body: 'Fresh ideas arrive at the next market open.',
          )
        else
          for (final idea in ideas.top(8))
            Padding(
              padding: const EdgeInsets.only(bottom: TWSpace.md),
              child: TWFloatingCard(
                key: Key('home_idea_${idea.symbol}'),
                onTap: () => onTap(idea),
                padding: const EdgeInsets.all(TWSpace.lg),
                child: Row(
                  children: [
                    // Final score visually dominant (the ring), tags secondary.
                    TWScoreRing(score: idea.score, size: 50, stroke: 4),
                    const SizedBox(width: TWSpace.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(idea.symbol, style: TWType.title3),
                              const SizedBox(width: TWSpace.sm),
                              _Source(label: idea.source.label),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(idea.reason,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TWType.caption
                                  .copyWith(color: TWColors.textTertiary)),
                        ],
                      ),
                    ),
                    const SizedBox(width: TWSpace.md),
                    TWSignalPill(signal: idea.signal),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class _Source extends StatelessWidget {
  const _Source({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: TWSpace.sm, vertical: 2),
      decoration: BoxDecoration(
        color: TWColors.accent.withValues(alpha: 0.16),
        borderRadius: TWRadius.rChip,
      ),
      child: Text(label,
          style: TWType.overline
              .copyWith(color: TWColors.accentBright, letterSpacing: 0.4)),
    );
  }
}

/// The best market/index to be in right now (Global Rotation), shown ABOVE the
/// best-stock ideas: "where to be" before "what to buy". Tapping opens the full
/// Global Rotation breakdown.
class _BestIndexCard extends StatelessWidget {
  const _BestIndexCard({required this.entry, this.onTap});
  final MarketRotation entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final rec = entry.recommendation.toUpperCase();
    final color = recColor(rec);
    return TWFloatingCard(
      key: const Key('home_best_index'),
      onTap: onTap,
      padding: const EdgeInsets.all(TWSpace.lg),
      child: Row(
        children: [
          TWScoreRing(score: entry.rotationScore, size: 50, stroke: 4),
          const SizedBox(width: TWSpace.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${entry.market.flag} ${entry.market.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TWType.title3,
                      ),
                    ),
                    const SizedBox(width: TWSpace.sm),
                    const _Source(label: 'Best Index'),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  'Top-ranked market in today\u2019s Global Rotation.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TWType.caption
                      .copyWith(color: TWColors.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: TWSpace.md),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: TWSpace.sm, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: TWRadius.rChip,
            ),
            child: Text(
              rec.isEmpty ? 'NEUTRAL' : rec,
              style: TWType.overline
                  .copyWith(color: color, letterSpacing: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}