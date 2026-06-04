import 'package:flutter/material.dart';

import '../models/market.dart';
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
    } finally {
      if (mounted) setState(() => _loading = false);
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
                child: _SummaryCard(
                  label: 'Index',
                  value: '${market.code} Comp.',
                  sub: '+0.84%',
                  subColor: AppColors.up,
                  icon: Icons.show_chart,
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
