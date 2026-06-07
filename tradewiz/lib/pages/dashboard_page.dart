import 'package:flutter/material.dart';

import '../models/market.dart';
import '../models/market_index.dart';
import '../models/screener_result.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/data_source.dart';
import '../services/repository_scope.dart';
import '../theme.dart';
import '../widgets/connection_pill.dart';

/// Clean overview: market summary cards + top movers for the selected market.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.market, this.repository});

  final Market market;
  final StockRepository? repository;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  StockRepository? _repo;
  bool _loading = false;
  DataSource? _source;
  List<ScreenerMatch> _movers = const [];
  MarketIndex? _index;
  bool _indexUnavailable = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repo ??= widget.repository ?? RepositoryScope.of(context);
    _load();
  }

  @override
  void didUpdateWidget(covariant DashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.market != widget.market) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // Index data and movers load independently: a movers/screen failure must
    // not blank the index, and vice versa.
    await Future.wait([_loadMovers(), _loadIndex()]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMovers() async {
    try {
      final res = await _repo!.screen(widget.market);
      if (!mounted) return;
      final movers = [...res.data.matches]
        ..sort((a, b) => b.changePercent.compareTo(a.changePercent));
      setState(() {
        _movers = movers.take(5).toList();
        _source = res.source;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _movers = const [];
        _source = e.statusCode == null ? DataSource.offline : DataSource.error;
      });
    }
  }

  Future<void> _loadIndex() async {
    try {
      final indices = await _repo!.marketIndices();
      if (!mounted) return;
      final match = indices.where((i) => i.market == widget.market.code);
      final idx = match.isNotEmpty ? match.first : null;
      setState(() {
        _index = idx;
        // Unavailable when the backend reported no data for this index.
        _indexUnavailable = idx == null || !idx.hasData;
      });
    } on ApiException {
      // Never fall back to fake index values: show the warning instead.
      if (!mounted) return;
      setState(() {
        _index = null;
        _indexUnavailable = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final market = widget.market;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Row(
            children: [
              const _SectionTitle('Overview'),
              const Spacer(),
              ConnectionPill(source: _source),
            ],
          ),
          const SizedBox(height: 8),
          ConnectionBanner(
            source: _source,
            onRetry: _load,
            retrying: _loading,
          ),
          _MarketHeader(market: market),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _IndexCard(
                  index: _index,
                  unavailable: _indexUnavailable,
                  loading: _loading && _index == null && !_indexUnavailable,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryCard(
                  label: 'Matches',
                  value: '${_movers.length} found',
                  sub: _source?.label ?? 'Loading…',
                  subColor: Colors.grey,
                  icon: Icons.list_alt,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _SectionTitle('Top Movers'),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_movers.isEmpty)
            const _EmptyState(message: 'No movers available for this market.')
          else
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < _movers.length; i++) ...[
                    _MoverTile(match: _movers[i]),
                    if (i != _movers.length - 1)
                      const Divider(height: 1, indent: 72),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MoverTile extends StatelessWidget {
  const _MoverTile({required this.match});
  final ScreenerMatch match;

  @override
  Widget build(BuildContext context) {
    final changeColor = match.isUp ? AppColors.up : AppColors.down;
    final sign = match.isUp ? '+' : '';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: AppColors.seed.withValues(alpha: 0.1),
        child: Text(
          match.symbol.characters.take(2).toString(),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: AppColors.seed,
          ),
        ),
      ),
      title: Text(match.symbol,
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(match.name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        '$sign${match.changePercent.toStringAsFixed(2)}%',
        style: TextStyle(
          color: changeColor,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _MarketHeader extends StatelessWidget {
  const _MarketHeader({required this.market});
  final Market market;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF1E88E5), Color(0xFF42A5F5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Text(market.flag, style: const TextStyle(fontSize: 36)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  market.code,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  market.name,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          Text(
            market.currency,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Real market-index card driven by `GET /v1/market/indices`. Shows the index
/// name, latest price, change, change %, status and update time. On a backend
/// failure (or no data) it shows a clear "Index data unavailable" warning
/// instead of any mock/hardcoded value.
class _IndexCard extends StatelessWidget {
  const _IndexCard({
    required this.index,
    required this.unavailable,
    required this.loading,
  });

  final MarketIndex? index;
  final bool unavailable;
  final bool loading;

  String _fmtPrice(double v) {
    // Group thousands; 2 decimals.
    final s = v.toStringAsFixed(2);
    final parts = s.split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (m) => '${m[1]},',
    );
    return '$intPart.${parts[1]}';
  }

  String _fmtUpdated(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final idx = index;
    if (unavailable || idx == null || !idx.hasData) {
      return Card(
        key: const Key('dashboard_index_unavailable'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.show_chart, color: Colors.grey, size: 22),
              const SizedBox(height: 12),
              const Text('Index',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 2),
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else ...[
                const Text(
                  'Index data unavailable',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: AppColors.down,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Could not load live index data.',
                  style: TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final up = idx.isUp;
    final color = up ? AppColors.up : AppColors.down;
    final sign = up ? '+' : '';
    final change = idx.change ?? 0;
    final pct = idx.changePercent ?? 0;
    final updated = _fmtUpdated(idx.updatedAt);
    return Card(
      key: const Key('dashboard_index_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.show_chart, color: AppColors.seed, size: 22),
                const Spacer(),
                _StatusChip(status: idx.status),
              ],
            ),
            const SizedBox(height: 12),
            Text(idx.name,
                key: const Key('dashboard_index_name'),
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 2),
            Text(
              _fmtPrice(idx.price!),
              key: const Key('dashboard_index_price'),
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              '$sign${change.toStringAsFixed(2)} '
              '($sign${pct.toStringAsFixed(2)}%)',
              key: const Key('dashboard_index_change'),
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w600, fontSize: 12),
            ),
            if (updated.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Updated $updated',
                key: const Key('dashboard_index_updated'),
                style: const TextStyle(color: Colors.grey, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final open = status == 'OPEN';
    final color = open ? AppColors.up : Colors.grey;
    return Container(
      key: const Key('dashboard_index_status'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: color, fontWeight: FontWeight.w700, fontSize: 10),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.subColor,
    required this.icon,
  });

  final String label;
  final String value;
  final String sub;
  final Color subColor;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.seed, size: 22),
            const SizedBox(height: 12),
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 2),
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              sub,
              style: TextStyle(color: subColor, fontWeight: FontWeight.w600, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(message, style: const TextStyle(color: Colors.grey)),
        ),
      ),
    );
  }
}
