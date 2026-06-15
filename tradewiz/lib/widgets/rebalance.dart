import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../models/broker.dart';
import '../models/phase3.dart';
import '../pages/ai_analysis_page.dart';
import '../pages/order_ticket_page.dart';
import '../repositories/stock_repository.dart';
import '../services/auth_scope.dart';
import '../services/portfolio_health_cache.dart';
import '../services/repository_scope.dart';
import '../theme.dart';
import '../theme_tradewizz.dart';
import 'ds/ds.dart';

Color actionColor(String action) => {
      'ADD': AppColors.up,
      'REDUCE': Colors.orange,
      'EXIT': AppColors.down,
    }[action] ??
    Colors.blueGrey;

IconData actionIcon(String action) => {
      'ADD': Icons.add_circle_outline,
      'REDUCE': Icons.remove_circle_outline,
      'EXIT': Icons.logout,
      'HOLD': Icons.check_circle_outline,
    }[action] ??
    Icons.info_outline;

/// "Portfolio Rebalancing AI" card (Account page) — recommended action count,
/// HIGH-priority count, and an estimated portfolio-score improvement, with a
/// tap-through to the detail page.
class RebalanceCard extends StatefulWidget {
  const RebalanceCard({super.key, this.repository, this.cache});

  final StockRepository? repository;

  /// Injectable local cache so reopening the page renders the last known
  /// report immediately (no spinner) while it revalidates in the background.
  final PortfolioInsightCache? cache;

  @override
  State<RebalanceCard> createState() => _RebalanceCardState();
}

class _RebalanceCardState extends State<RebalanceCard> {
  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  bool _loading = true;
  bool _error = false;
  RebalanceReport? _data;
  bool _cacheSeeded = false;
  late final PortfolioInsightCache _cache =
      widget.cache ?? SharedPrefsPortfolioInsightCache();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading && _data == null) _load();
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() {
        _loading = false;
        _data = null;
      });
      return;
    }
    // Seed from cache once (non-blocking) so a reopen shows the last report
    // instantly; the fresh fetch below runs in parallel and overwrites it.
    if (!_cacheSeeded) {
      _cacheSeeded = true;
      unawaited(() async {
        try {
          final cached =
              await _cache.read(PortfolioInsightFeature.rebalance, token);
          if (cached != null && mounted && _data == null) {
            setState(() {
              _data = RebalanceReport.fromJson(cached);
              _loading = false;
              _error = false;
            });
          }
        } catch (_) {
          // Ignore a bad/unavailable cache; the fresh fetch covers it.
        }
      }());
    }
    // Only show the spinner when there is nothing cached to display yet.
    setState(() => _loading = _data == null);
    try {
      final raw = await _repo.rawRebalance(token);
      if (!mounted) return;
      setState(() {
        _data = RebalanceReport.fromJson(raw);
        _loading = false;
        _error = false;
      });
      unawaited(_cache.write(PortfolioInsightFeature.rebalance, token, raw));
    } catch (_) {
      // Any failure (ApiException, timeout, socket, parse): keep showing cached
      // data if we have it; only flag error when there is nothing to show.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _data == null;
      });
    }
  }

  void _openDetail() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RebalanceDetailPage(repository: widget.repository),
    )).then((_) {
      if (mounted) _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('rebalance_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.balance, color: AppColors.seed, size: 20),
            const SizedBox(width: 8),
            const Text('Portfolio Rebalancing AI',
                key: Key('rebalance_title'),
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: TWColors.textPrimary)),
          ],
        ),
        const SizedBox(height: 8),
        TWFloatingCard(
          key: const Key('rebalance_card'),
          onTap: _data == null ? null : _openDetail,
          child: _buildBody(),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading && _data == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            key: Key('rebalance_loading'),
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (_token == null) {
      return const Text('Sign in for AI rebalancing guidance.',
          style: TextStyle(color: TWColors.textTertiary));
    }
    if (_error || _data == null) {
      return const Text('Rebalancing unavailable.',
          key: Key('rebalance_error'),
          style: TextStyle(color: TWColors.down));
    }
    final data = _data!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _stat('Actions', '${data.actionCount}',
                key: const Key('rebalance_action_count')),
            _stat('HIGH priority', '${data.highPriorityCount}',
                color: AppColors.down,
                key: const Key('rebalance_high_count')),
            _stat(
              'Est. +score',
              '+${data.estimatedScoreImprovement.toStringAsFixed(0)}',
              color: AppColors.up,
              key: const Key('rebalance_score_improve'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(data.summary,
            style: const TextStyle(
                fontSize: 12, color: TWColors.textSecondary)),
        const SizedBox(height: 8),
        const Row(
          children: [
            Spacer(),
            Text('Tap to review actions',
                style: TextStyle(
                    color: AppColors.seed,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            Icon(Icons.chevron_right, color: AppColors.seed, size: 18),
          ],
        ),
      ],
    );
  }

  Widget _stat(String label, String value, {Color? color, Key? key}) {
    return Expanded(
      child: Column(
        key: key,
        children: [
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                  color: color ?? TWColors.textPrimary)),
          const SizedBox(height: 2),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: TWColors.textTertiary, fontSize: 12)),
        ],
      ),
    );
  }
}

/// Rebalance detail page — list of ADD / HOLD / REDUCE / EXIT actions, each
/// with Buy More / Sell / View Analysis (all simulation-only).
class RebalanceDetailPage extends StatefulWidget {
  const RebalanceDetailPage({super.key, this.repository, this.cache});

  final StockRepository? repository;

  /// Injectable local cache so the detail page renders the last known report
  /// instantly and survives a failing refresh (no more "unavailable" when the
  /// backend hiccups but we already have a cached report).
  final PortfolioInsightCache? cache;

  @override
  State<RebalanceDetailPage> createState() => _RebalanceDetailPageState();
}

class _RebalanceDetailPageState extends State<RebalanceDetailPage> {
  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);
  late final PortfolioInsightCache _cache =
      widget.cache ?? SharedPrefsPortfolioInsightCache();

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  bool _loading = true;
  bool _cacheSeeded = false;
  RebalanceReport? _data;

  /// Symbol -> shares currently held in the simulation. Used to show the
  /// holdings summary + drag-to-sell slider in the order ticket when trimming.
  Map<String, double> _ownedShares = const {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() => _loading = false);
      return;
    }
    // Seed from the shared rebalance cache once (non-blocking) so a reopen /
    // refresh shows the last report instantly while the fresh fetch runs.
    if (!_cacheSeeded) {
      _cacheSeeded = true;
      unawaited(() async {
        try {
          final cached =
              await _cache.read(PortfolioInsightFeature.rebalance, token);
          if (cached != null && mounted && _data == null) {
            setState(() {
              _data = RebalanceReport.fromJson(cached);
              _loading = false;
            });
          }
        } catch (_) {/* bad/empty cache: the fresh fetch covers it */}
      }());
    }
    // Only spin when there is nothing cached to show yet.
    setState(() => _loading = _data == null);
    // Refresh held quantities in parallel (best-effort) so a Sell from here
    // knows the max and can show the lot info + slider. A failure is harmless.
    unawaited(() async {
      try {
        final positions = await _repo.simPositions(token);
        if (!mounted) return;
        setState(() {
          _ownedShares = {
            for (final p in positions) p.symbol: p.quantity,
          };
        });
      } catch (_) {/* keep whatever we had */}
    }());
    try {
      final raw = await _repo.rawRebalance(token);
      if (!mounted) return;
      setState(() {
        _data = RebalanceReport.fromJson(raw);
        _loading = false;
      });
      unawaited(_cache.write(PortfolioInsightFeature.rebalance, token, raw));
    } catch (_) {
      // Any failure: keep the cached report if we have one; only fall through to
      // "unavailable" when there is nothing to show.
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _ticket(RebalanceAction a, OrderSide side) async {
    // When selling a held position, pass the owned shares so the ticket shows
    // the holdings summary (e.g. "1,200 shares (12 lots)") + the drag slider.
    final owned = _ownedShares[a.symbol] ?? 0;
    final sellingHeld = side == OrderSide.sell && owned > 0;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrderTicketPage(
        symbol: a.symbol,
        market: a.market,
        side: side,
        repository: _repo,
        initialQuantity: sellingHeld ? owned : null,
        maxQuantity: sellingHeld ? owned : null,
      ),
    ));
    if (mounted) await _load();
  }

  void _analysis(RebalanceAction a) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AiAnalysisPage(
        market: a.market,
        repository: widget.repository,
        initialSymbol: a.symbol,
        autoRun: true,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      backgroundColor: TWColors.bgBase,
      appBar: AppBar(
        backgroundColor: TWColors.bgBase,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Portfolio Rebalancing AI',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: TWColors.textPrimary)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : data == null
              ? const Center(
                  child: Text('Rebalancing unavailable.',
                      style: TextStyle(color: AppColors.down)))
              : ListView(
                  key: const Key('rebalance_detail_list'),
                  padding: const EdgeInsets.all(16),
                  children: [
                    _SummaryHeader(data: data),
                    const SizedBox(height: 12),
                    if (data.actions.isEmpty)
                      const TWFloatingCard(
                        child: Center(
                          child: Text(
                            'No simulated holdings to rebalance yet.',
                            key: Key('rebalance_detail_empty'),
                            style: TextStyle(color: TWColors.textTertiary),
                          ),
                        ),
                      )
                    else
                      for (final a in data.actions)
                        _ActionCard(
                          a: a,
                          onBuy: () => _ticket(a, OrderSide.buy),
                          onSell: () => _ticket(a, OrderSide.sell),
                          onAnalysis: () => _analysis(a),
                        ),
                  ],
                ),
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.data});
  final RebalanceReport data;

  @override
  Widget build(BuildContext context) {
    return TWFloatingCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Profile: ${data.profile}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: TWColors.textPrimary)),
                const Spacer(),
                Text('Score ${data.portfolioScore.toStringAsFixed(0)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                        color: TWColors.textPrimary)),
              ],
            ),
            const SizedBox(height: 6),
            Text(data.summary,
                style: const TextStyle(
                    fontSize: 12, color: TWColors.textSecondary)),
            for (final w in data.warnings) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: Colors.orange),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(w,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.orange)),
                  ),
                ],
              ),
            ],
          ],
        ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.a,
    required this.onBuy,
    required this.onSell,
    required this.onAnalysis,
  });

  final RebalanceAction a;
  final VoidCallback onBuy;
  final VoidCallback onSell;
  final VoidCallback onAnalysis;

  @override
  Widget build(BuildContext context) {
    return TWFloatingCard(
      key: Key('rebalance_action_${a.symbol}'),
      padding: const EdgeInsets.all(14),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(actionIcon(a.action),
                    color: actionColor(a.action), size: 20),
                const SizedBox(width: 8),
                Text('${a.market.flag} ${a.symbol}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: TWColors.textPrimary)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: actionColor(a.action).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(a.action,
                      style: TextStyle(
                          color: actionColor(a.action),
                          fontWeight: FontWeight.w800,
                          fontSize: 12)),
                ),
                const Spacer(),
                if (a.priority == 'HIGH')
                  const Text('HIGH',
                      style: TextStyle(
                          color: AppColors.down,
                          fontWeight: FontWeight.w800,
                          fontSize: 12)),
              ],
            ),
            const SizedBox(height: 8),
            Text(a.reason,
                style: const TextStyle(
                    fontSize: 12, color: TWColors.textSecondary)),
            const SizedBox(height: 8),
            Row(
              children: [
                _kv('Current', '${a.currentWeight.toStringAsFixed(0)}%'),
                const SizedBox(width: 16),
                _kv('Target', '${a.targetWeight.toStringAsFixed(0)}%'),
                const SizedBox(width: 16),
                _kv('Score', a.score.toStringAsFixed(0)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: Key('rebalance_buy_${a.symbol}'),
                    onPressed: onBuy,
                    child: const Text('Buy More'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: Key('rebalance_sell_${a.symbol}'),
                    onPressed: onSell,
                    child: const Text('Sell'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: Key('rebalance_analysis_${a.symbol}'),
                    onPressed: onAnalysis,
                    child: const Text('Analysis'),
                  ),
                ),
              ],
            ),
          ],
        ),
    );
  }

  Widget _kv(String k, String v) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$k: ',
              style: const TextStyle(
                  color: TWColors.textTertiary, fontSize: 12)),
          Text(v,
              style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: TWColors.textPrimary)),
        ],
      );
}
