import 'package:flutter/material.dart';

import '../models/broker.dart';
import '../models/market.dart';
import '../models/screener_category.dart';
import '../models/screener_result.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/data_source.dart';
import '../services/repository_scope.dart';
import '../theme.dart';
import '../widgets/category_badge.dart';
import '../widgets/connection_pill.dart';
import 'ai_analysis_page.dart';
import 'order_ticket_page.dart';

/// Screener page: runs `/screen/{market}` and lists tagged matches with
/// market + category filters. iOS-first UX (pull-to-refresh, clean cards).
class ScreenerPage extends StatefulWidget {
  const ScreenerPage({super.key, this.market, this.repository});

  /// Market preselected from the app shell.
  final Market? market;
  final StockRepository? repository;

  @override
  State<ScreenerPage> createState() => _ScreenerPageState();
}

class _ScreenerPageState extends State<ScreenerPage> {
  late final StockRepository _repo = widget.repository ?? StockRepository();

  late Market _market = widget.market ?? Market.idx;
  ScreenerCategory? _categoryFilter;
  double _minScore = 0;

  // Pagination: requested top-N grows by _pageSize up to _maxLimit.
  static const int _pageSize = 50;
  static const int _maxLimit = 200;
  int _limit = _pageSize;
  bool _loadingMore = false;

  bool _loading = false;
  String? _error;
  ScreenerResult? _result;
  DataSource? _source;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void didUpdateWidget(covariant ScreenerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.market != null && widget.market != _market) {
      _market = widget.market!;
      _run();
    }
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Pass params only when a filter is active (limit always bounds results).
      final result = await _repo.screen(
        _market,
        limit: _limit,
        minScore: _minScore > 0 ? _minScore : null,
        categories: _categoryFilter != null
            ? [_categoryFilter!.wireName]
            : null,
      );
      if (!mounted) return;
      setState(() {
        _result = result.data;
        _source = result.source;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _source = e.statusCode == null ? DataSource.offline : DataSource.error;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not run screener. $e';
        _source = DataSource.error;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectMarket(Market m) {
    if (m == _market) return;
    setState(() {
      _market = m;
      _limit = _pageSize; // reset pagination on context change
    });
    _run();
  }

  void _selectCategory(ScreenerCategory? c) {
    setState(() {
      _categoryFilter = c;
      _limit = _pageSize;
    });
    _run(); // re-query server-side with the category filter
  }

  void _selectMinScore(double v) {
    setState(() {
      _minScore = v;
      _limit = _pageSize;
    });
    _run();
  }

  bool get _canLoadMore =>
      (_result?.hasMore ?? false) && _limit < _maxLimit;

  Future<void> _loadMore() async {
    if (!_canLoadMore || _loadingMore) return;
    setState(() {
      _limit = (_limit + _pageSize).clamp(_pageSize, _maxLimit);
      _loadingMore = true;
    });
    try {
      await _run();
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _openAnalysis(ScreenerMatch match) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnalysisDetailPage(
          symbol: match.symbol,
          market: _market,
          repository: widget.repository,
        ),
      ),
    );
  }

  /// Open the shared simulated order ticket for a screener match. Reuses the
  /// exact same OrderTicketPage as Analysis/Watchlist/Account — simulation only.
  void _openTicket(ScreenerMatch match, OrderSide side) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OrderTicketPage(
          symbol: match.symbol,
          market: _market,
          side: side,
          repository: widget.repository ?? RepositoryScope.of(context),
        ),
      ),
    );
  }

  /// Swipe-left action sheet: Buy / Sell. Never deletes the row.
  Future<void> _showBuySellMenu(ScreenerMatch match) async {
    final choice = await showModalBottomSheet<OrderSide>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              key: const Key('screener_action_menu'),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('${match.symbol} · ${_market.code}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 16)),
            ),
            ListTile(
              key: const Key('screener_action_buy'),
              leading: const Icon(Icons.add_circle_outline,
                  color: AppColors.up),
              title: const Text('Buy (simulated)'),
              onTap: () => Navigator.of(ctx).pop(OrderSide.buy),
            ),
            ListTile(
              key: const Key('screener_action_sell'),
              leading: const Icon(Icons.remove_circle_outline,
                  color: AppColors.down),
              title: const Text('Sell (simulated)'),
              onTap: () => Navigator.of(ctx).pop(OrderSide.sell),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                'Simulation mode only. No real broker order will be sent.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
    if (choice != null && mounted) _openTicket(match, choice);
  }

  // Server already filters; keep a defensive local pass for fallback data.
  List<ScreenerMatch> get _filtered {
    final matches = _result?.matches ?? [];
    return matches.where((m) {
      if (_minScore > 0 && m.score < _minScore) return false;
      if (_categoryFilter != null && !m.hasCategory(_categoryFilter!)) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _MarketFilterBar(selected: _market, onSelected: _selectMarket),
        _CategoryFilterBar(
          selected: _categoryFilter,
          onSelected: _selectCategory,
        ),
        _MinScoreBar(selected: _minScore, onSelected: _selectMinScore),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Text(
                'Data source',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              ConnectionPill(source: _source),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ConnectionBanner(
            source: _source,
            onRetry: _run,
            retrying: _loading,
          ),
        ),
        if (_result != null) _CacheBanner(result: _result!),
        const Divider(height: 1),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ScreenerError(message: _error!, onRetry: _run);
    }
    final matches = _filtered;
    if (matches.isEmpty) {
      return _ScreenerEmpty(
        hasFilter: _categoryFilter != null,
        onClearFilter: () => setState(() => _categoryFilter = null),
        onRefresh: _run,
      );
    }
    final result = _result;
    return RefreshIndicator(
      onRefresh: _run,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        // +1 for the footer (count + optional Load More).
        itemCount: matches.length + 1,
        separatorBuilder: (_, index) => const SizedBox(height: 12),
        itemBuilder: (_, i) {
          if (i < matches.length) {
            final match = matches[i];
            return Dismissible(
              key: Key('screener_row_${match.symbol}_${_market.code}'),
              direction: DismissDirection.endToStart,
              // Swipe-left reveals a Buy/Sell menu; it never deletes the row.
              confirmDismiss: (_) async {
                await _showBuySellMenu(match);
                return false;
              },
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.swap_horiz, size: 20),
                    SizedBox(width: 6),
                    Text('Buy / Sell',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              child: _MatchCard(
                match: match,
                onTap: () => _openAnalysis(match),
              ),
            );
          }
          return _ScreenerFooter(
            shown: result?.shownCount ?? matches.length,
            total: result?.totalCount ?? matches.length,
            canLoadMore: _canLoadMore,
            loadingMore: _loadingMore,
            atMax: _limit >= _maxLimit,
            onLoadMore: _loadMore,
          );
        },
      ),
    );
  }
}

/// Market-close cache status banner: shows the "Cached market-close result"
/// label + generated_at, and an open-market notice when the market is open.
/// Hidden when the server reports no cache metadata (older backends).
class _CacheBanner extends StatelessWidget {
  const _CacheBanner({required this.result});

  final ScreenerResult result;

  String _formatGeneratedAt() {
    final dt = result.generatedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    // Only render when the backend actually reported cache metadata.
    final hasMeta = result.cached ||
        result.marketStatus != null ||
        result.nextRefreshRule != null;
    if (!hasMeta) return const SizedBox.shrink();

    final open = result.isMarketOpen;
    final children = <Widget>[
      Row(
        children: [
          Icon(
            result.cached ? Icons.history : Icons.bolt,
            size: 16,
            color: AppColors.seed,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              result.cached
                  ? 'Cached market-close result'
                  : 'Fresh market-close result',
              key: const Key('screener_cache_label'),
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
          Text(
            _formatGeneratedAt(),
            key: const Key('screener_generated_at'),
            style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5),
          ),
        ],
      ),
    ];

    if (open) {
      children.add(const SizedBox(height: 6));
      children.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline,
                size: 14, color: Colors.amber.shade800),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                'Screening uses latest saved result to avoid slow loading '
                'during market hours.',
                key: Key('screener_open_warning'),
                style: TextStyle(fontSize: 11.5),
              ),
            ),
          ],
        ),
      );
    } else if (result.nextRefreshRule != null) {
      children.add(const SizedBox(height: 4));
      children.add(
        Text(
          result.nextRefreshRule!,
          key: const Key('screener_refresh_rule'),
          style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
        ),
      );
    }

    if (result.warning != null && open) {
      children.add(const SizedBox(height: 4));
      children.add(
        Text(
          result.warning!,
          key: const Key('screener_cache_warning'),
          style: TextStyle(color: Colors.amber.shade900, fontSize: 11),
        ),
      );
    }

    return Container(
      width: double.infinity,
      color: open
          ? Colors.amber.withValues(alpha: 0.10)
          : AppColors.seed.withValues(alpha: 0.06),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// "Showing X of Y" count + Load More control at the bottom of the list.
class _ScreenerFooter extends StatelessWidget {
  const _ScreenerFooter({
    required this.shown,
    required this.total,
    required this.canLoadMore,
    required this.loadingMore,
    required this.atMax,
    required this.onLoadMore,
  });

  final int shown;
  final int total;
  final bool canLoadMore;
  final bool loadingMore;
  final bool atMax;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        children: [
          Text(
            'Showing $shown of $total',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
          const SizedBox(height: 10),
          if (canLoadMore)
            SizedBox(
              width: double.infinity,
              child: loadingMore
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : OutlinedButton.icon(
                      onPressed: onLoadMore,
                      icon: const Icon(Icons.expand_more),
                      label: const Text('Load more'),
                    ),
            )
          else if (atMax && total > shown)
            Text(
              'Showing the top $shown (max).',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

class _MarketFilterBar extends StatelessWidget {
  const _MarketFilterBar({required this.selected, required this.onSelected});
  final Market selected;
  final ValueChanged<Market> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          for (final m in Market.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: m == selected,
                label: Text('${m.flag} ${m.code}'),
                onSelected: (_) => onSelected(m),
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryFilterBar extends StatelessWidget {
  const _CategoryFilterBar({required this.selected, required this.onSelected});
  final ScreenerCategory? selected;
  final ValueChanged<ScreenerCategory?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              selected: selected == null,
              label: const Text('All'),
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final c in ScreenerCategory.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                selected: c == selected,
                avatar: Icon(c.icon, size: 16, color: c.color),
                label: Text(c.label),
                onSelected: (sel) => onSelected(sel ? c : null),
              ),
            ),
        ],
      ),
    );
  }
}

/// Quick min-score selector (chips). 0 means "no minimum".
class _MinScoreBar extends StatelessWidget {
  const _MinScoreBar({required this.selected, required this.onSelected});
  final double selected;
  final ValueChanged<double> onSelected;

  static const _options = <double>[0, 50, 70, 90];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              'Min score',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ),
          for (final v in _options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: v == selected,
                label: Text(v == 0 ? 'Any' : '≥ ${v.toInt()}'),
                onSelected: (_) => onSelected(v),
              ),
            ),
        ],
      ),
    );
  }
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match, this.onTap});
  final ScreenerMatch match;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final changeColor = match.isUp ? AppColors.up : AppColors.down;
    final sign = match.isUp ? '+' : '';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
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
                        match.symbol,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                      Text(
                        match.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      match.price.toStringAsFixed(match.price >= 100 ? 0 : 2),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '$sign${match.changePercent.toStringAsFixed(2)}%',
                      style: TextStyle(
                        color: changeColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                _ScorePill(score: match.score),
              ],
            ),
            if (match.categories.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in match.categories)
                    CategoryBadge(category: c, compact: true),
                ],
              ),
            ],
          ],
        ),
        ),
      ),
    );
  }
}

class _ScorePill extends StatelessWidget {
  const _ScorePill({required this.score});
  final double score;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.seed.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        score.toStringAsFixed(0),
        style: const TextStyle(
          color: AppColors.seed,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ScreenerError extends StatelessWidget {
  const _ScreenerError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.down),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _ScreenerEmpty extends StatelessWidget {
  const _ScreenerEmpty({
    required this.hasFilter,
    required this.onClearFilter,
    required this.onRefresh,
  });
  final bool hasFilter;
  final VoidCallback onClearFilter;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_alt_off_outlined,
                size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              hasFilter
                  ? 'No matches for this category.'
                  : 'No screener matches found.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            if (hasFilter)
              FilledButton.tonal(
                onPressed: onClearFilter,
                child: const Text('Clear filter'),
              )
            else
              FilledButton.tonal(
                onPressed: onRefresh,
                child: const Text('Refresh'),
              ),
          ],
        ),
      ),
    );
  }
}
