import 'package:flutter/material.dart';

import '../models/market.dart';
import '../models/screener_category.dart';
import '../models/screener_result.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/data_source.dart';
import '../theme.dart';
import '../widgets/category_badge.dart';
import '../widgets/connection_pill.dart';
import 'ai_analysis_page.dart';

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
      final result = await _repo.screen(_market);
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
    setState(() => _market = m);
    _run();
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

  List<ScreenerMatch> get _filtered {
    final matches = _result?.matches ?? [];
    if (_categoryFilter == null) return matches;
    return matches.where((m) => m.hasCategory(_categoryFilter!)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _MarketFilterBar(selected: _market, onSelected: _selectMarket),
        _CategoryFilterBar(
          selected: _categoryFilter,
          onSelected: (c) => setState(() => _categoryFilter = c),
        ),
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
    return RefreshIndicator(
      onRefresh: _run,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: matches.length,
        separatorBuilder: (_, index) => const SizedBox(height: 12),
        itemBuilder: (_, i) => _MatchCard(
          match: matches[i],
          onTap: () => _openAnalysis(matches[i]),
        ),
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
