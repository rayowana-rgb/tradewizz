import 'package:flutter/material.dart';

import '../home/activation_scope.dart';
import '../home/todays_ideas.dart';
import '../models/market.dart';
import '../models/market_index.dart';
import '../models/market_overview.dart';
import '../models/phase2.dart';
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
import '../theme.dart';
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
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('home_list'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _HeroCard(
            greeting: _greeting(),
            idea: ideas.ideas.isNotEmpty ? ideas.ideas.first : null,
            fallback: brief?.topOpportunity,
            onView: _openAnalysis,
          ),
          const SizedBox(height: 16),
          _BriefCard(brief: brief),
          const SizedBox(height: 16),
          _IndexCard(
            market: widget.market,
            index: _index,
            overview: _overview,
            condition: _condition,
            ideas: ideas,
          ),
          const SizedBox(height: 16),
          _PortfolioCard(
            account: _account,
            positions: _positions,
            onOpenPortfolio: _openPortfolio,
          ),
          const SizedBox(height: 16),
          _WatchlistCard(market: widget.market),
          const SizedBox(height: 16),
          _IdeasSection(ideas: ideas, onTap: _openIdea),
        ],
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

  void _openPortfolio() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AccountPage(repository: _repo),
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
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1565C0), Color(0xFF1E88E5)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(greeting,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    const Text("Today's Best Idea",
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            letterSpacing: 0.4,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              if (hasIdea) _Confidence(score: score),
            ],
          ),
          if (hasIdea) ...[
            const SizedBox(height: 8),
            // Compact identity line: ticker + signal + score on one row.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text('🔥', style: TextStyle(fontSize: 20)),
                const SizedBox(width: 6),
                Text(symbol,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800)),
                const SizedBox(width: 10),
                _SignalPill(signal: signal),
                const SizedBox(width: 8),
                Text('Score ${score.toStringAsFixed(0)}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ],
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(tags.join('  •  '),
                  key: const Key('home_hero_tags'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 8),
            Text(reason,
                key: const Key('home_hero_reason'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, height: 1.3)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: FilledButton(
                key: const Key('home_hero_cta'),
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF1565C0)),
                onPressed: onView,
                child: const Text('View Analysis',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ] else ...[
            const SizedBox(height: 12),
            Text(reason,
                style: const TextStyle(color: Colors.white, height: 1.35)),
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

class _SignalPill extends StatelessWidget {
  const _SignalPill({required this.signal});
  final String signal;
  @override
  Widget build(BuildContext context) {
    final s = signal.toUpperCase();
    final isBuy = s.contains('BUY');
    final isSell = s.contains('SELL');
    final color = isBuy
        ? AppColors.up
        : (isSell ? AppColors.down : Colors.orange);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: color, borderRadius: BorderRadius.circular(8)),
      child: Text(s,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
    );
  }
}

class _Confidence extends StatelessWidget {
  const _Confidence({required this.score});
  final double score;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Text('Confidence',
            style: TextStyle(color: Colors.white70, fontSize: 11)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Bare number kept as its own Text so tests can assert on it.
            Text(score.toStringAsFixed(0),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            const Text('%',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ],
    );
  }
}

// =========================================================================
// 2) Morning Brief (max 3 bullets)
// =========================================================================
class _BriefCard extends StatelessWidget {
  const _BriefCard({required this.brief});
  final MorningBrief? brief;

  @override
  Widget build(BuildContext context) {
    final bullets = _bullets();
    return Card(
      key: const Key('home_brief'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.wb_sunny_outlined, color: AppColors.seed, size: 20),
                SizedBox(width: 8),
                Text('Morning Brief',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                Spacer(),
                Text('15s read',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 10),
            if (bullets.isEmpty)
              const Text('Your brief is being prepared.',
                  style: TextStyle(color: Colors.grey))
            else
              for (final b in bullets)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  ',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      Expanded(child: Text(b)),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  List<String> _bullets() {
    final b = brief;
    if (b == null) return const [];
    final out = <String>[];
    if (b.headline.isNotEmpty) out.add(b.headline);
    if (b.topOpportunity != null && out.length < 3) {
      final o = b.topOpportunity!;
      out.add('${o.symbol}: ${o.reason.isEmpty ? o.signal : o.reason}');
    }
    if (b.strongestSector.isNotEmpty && out.length < 3) {
      out.add('Strongest sector: ${b.strongestSector}');
    }
    for (final n in b.notes) {
      if (out.length >= 3) break;
      out.add(n);
    }
    return out.take(3).toList();
  }
}

// =========================================================================
// 2b) Index movement + market activity + Fear/Greed (Phase C/D/E)
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
      'EXTREME_FEAR' => AppColors.down,
      'FEAR' => Colors.orange,
      'GREED' => AppColors.up,
      'EXTREME_GREED' => const Color(0xFF1B8E3D),
      _ => Colors.grey,
    };

class _IndexCard extends StatelessWidget {
  const _IndexCard({
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
    final idx = index;
    // Value traded: prefer the exchange total; otherwise fall back to the
    // aggregate of Today's Ideas (clearly labelled) so we never fabricate an
    // exchange-wide number.
    final exchangeValue = overview?.totalValueTraded;
    final valueLabel =
        exchangeValue != null ? 'Value Traded Today' : 'Top Ideas Value Traded';
    final valueText = exchangeValue != null
        ? _compactMoney(market, exchangeValue)
        : (ideas.ideas.isEmpty
            ? 'n/a'
            : '${ideas.ideas.length} ideas');

    return Card(
      key: const Key('home_index_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        idx?.name ?? '${market.code} Index',
                        key: const Key('home_index_name'),
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                      Text(
                        idx?.symbol ?? '',
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                _ConditionBadge(condition: condition),
              ],
            ),
            const SizedBox(height: 12),
            if (idx != null && idx.hasData)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    idx.price!.toStringAsFixed(2),
                    key: const Key('home_index_price'),
                    style: const TextStyle(
                        fontWeight: FontWeight.w900, fontSize: 24),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      '${idx.isUp ? '+' : ''}'
                      '${(idx.change ?? 0).toStringAsFixed(2)} '
                      '(${idx.isUp ? '+' : ''}'
                      '${(idx.changePercent ?? 0).toStringAsFixed(2)}%)',
                      key: const Key('home_index_change'),
                      style: TextStyle(
                        color: idx.isUp ? AppColors.up : AppColors.down,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              )
            else
              Text(
                idx == null
                    ? 'Index data loading…'
                    : 'Index data unavailable',
                key: const Key('home_index_unavailable'),
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                _MiniStat(
                  label: valueLabel,
                  value: valueText,
                  valueKey: const Key('home_value_traded'),
                ),
                const SizedBox(width: 24),
                _MiniStat(
                  label: 'Status',
                  value: idx?.status ?? '—',
                ),
              ],
            ),
            if (condition.isKnown && condition.reason.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                condition.reason,
                key: const Key('home_condition_reason'),
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConditionBadge extends StatelessWidget {
  const _ConditionBadge({required this.condition});
  final MarketCondition condition;

  @override
  Widget build(BuildContext context) {
    final color = _conditionColor(condition.condition);
    return Container(
      key: const Key('home_condition_badge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            condition.label,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 12),
          ),
          if (condition.isKnown)
            Text(
              '${condition.score}/100',
              style: TextStyle(color: color, fontSize: 10),
            ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value, this.valueKey});
  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Colors.grey, fontSize: 11)),
        const SizedBox(height: 2),
        Text(value,
            key: valueKey,
            style: const TextStyle(
                fontWeight: FontWeight.w800, fontSize: 14)),
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
      return Card(
        key: const Key('home_portfolio'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('My Portfolio',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              SizedBox(height: 8),
              Text('Start a simulated portfolio to track P&L here.',
                  style: TextStyle(color: Colors.grey)),
            ],
          ),
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

    return Card(
      key: const Key('home_portfolio'),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0D47A1), Color(0xFF1565C0), Color(0xFF1E88E5)],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('💼  MY PORTFOLIO',
                    style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        letterSpacing: 0.8)),
                const Spacer(),
                _Pill(text: '${positions.length} '
                    '${positions.length == 1 ? 'Position' : 'Positions'}'),
              ],
            ),
            const SizedBox(height: 12),
            // 1) Total value — the loudest element.
            Text(_money(a.equity, a.currency),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                  fontFeatures: [FontFeature.tabularFigures()],
                )),
            const SizedBox(height: 8),
            // 2) Total return.
            Row(
              children: [
                Icon(totalUp ? Icons.arrow_upward : Icons.arrow_downward,
                    color: Colors.white, size: 16),
                const SizedBox(width: 2),
                Text(
                  '${totalUp ? '+' : '-'}${_money(totalPnl.abs(), a.currency)}'
                  '  (${totalUp ? '+' : ''}${totalPct.toStringAsFixed(2)}%)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 3) Today's P/L.
            _todayRow(todayPnl, todayPct, a.currency),
            if (winner != null || largest != null) ...[
              const SizedBox(height: 14),
              const Divider(color: Colors.white24, height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (winner != null)
                    Expanded(
                      child: _PortfolioMiniStat(
                        label: 'Top Winner',
                        symbol: winner.symbol,
                        value: _pct(winner),
                        up: _ret(winner) >= 0,
                      ),
                    ),
                  if (winner != null && largest != null)
                    Container(
                        width: 1,
                        height: 34,
                        color: Colors.white24,
                        margin:
                            const EdgeInsets.symmetric(horizontal: 12)),
                  if (largest != null)
                    Expanded(
                      child: _PortfolioMiniStat(
                        label: 'Largest Position',
                        symbol: largest.symbol,
                        value: '${_weight(largest, a).toStringAsFixed(0)}%',
                        up: null,
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('home_portfolio_cta'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF0D47A1),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: onOpenPortfolio,
                child: const Text('Open Portfolio',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _todayRow(double v, double pct, String currency) {
    final up = v >= 0;
    return Row(
      children: [
        const Text('Today  ',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        Icon(up ? Icons.arrow_upward : Icons.arrow_downward,
            color: Colors.white70, size: 13),
        Text(
          '${up ? '+' : '-'}${_money(v.abs(), currency)} '
          '(${up ? '+' : ''}${pct.toStringAsFixed(2)}%)',
          style: const TextStyle(
            color: Colors.white70,
            fontWeight: FontWeight.w600,
            fontSize: 13,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
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

class _PortfolioMiniStat extends StatelessWidget {
  const _PortfolioMiniStat({
    required this.label,
    required this.symbol,
    required this.value,
    required this.up,
  });
  final String label;
  final String symbol;
  final String value;
  final bool? up; // null = neutral (no arrow / white text)

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(symbol,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 15)),
            const SizedBox(width: 6),
            if (up != null)
              Icon(up! ? Icons.arrow_upward : Icons.arrow_downward,
                  color: Colors.white, size: 12),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
      ],
    );
  }
}

// =========================================================================
// 4) Watchlist insights
// =========================================================================
class _WatchlistCard extends StatelessWidget {
  const _WatchlistCard({required this.market});
  final Market market;

  @override
  Widget build(BuildContext context) {
    final store = WatchlistScope.maybeOf(context);
    final items =
        store?.forMarket(market) ?? const <WatchlistItem>[];
    return Card(
      key: const Key('home_watchlist'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Your Watchlist',
                style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const Text('Add symbols to see daily highlights.',
                  style: TextStyle(color: Colors.grey))
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final i in items.take(6))
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(i.symbol),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.bolt, size: 16, color: Colors.orange),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'AI Alert: ${items.first.symbol} approaching a key level.',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// 5) Today's Ideas
// =========================================================================
class _IdeasSection extends StatelessWidget {
  const _IdeasSection({required this.ideas, required this.onTap});
  final TodaysIdeas ideas;
  final ValueChanged<TradeIdea> onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('home_ideas'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text("Today's Ideas",
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        ),
        if (ideas.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Fresh ideas arrive at the next market open.',
                  style: TextStyle(color: Colors.grey)),
            ),
          )
        else
          for (final idea in ideas.top(8))
            Card(
              child: ListTile(
                key: Key('home_idea_${idea.symbol}'),
                onTap: () => onTap(idea),
                title: Row(
                  children: [
                    Text(idea.symbol,
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(width: 8),
                    _Source(label: idea.source.label),
                  ],
                ),
                subtitle: Text(idea.reason,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(idea.score.toStringAsFixed(0),
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 16)),
                    Text(idea.signal,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.grey)),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.seed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.seed)),
    );
  }
}
