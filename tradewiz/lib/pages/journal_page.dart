import 'package:flutter/material.dart';

import '../models/phase2.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';
import '../widgets/portfolio_manager.dart';
import 'ai_analysis_page.dart';

/// Portfolio Journal — a research diary of simulated buys/sells with the
/// snapshot (score / signal / radar rank / portfolio health) at purchase, plus
/// aggregate stats. Also hosts the AI Portfolio Manager card. Simulation only.
class JournalPage extends StatefulWidget {
  const JournalPage({super.key, this.repository});

  final StockRepository? repository;

  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> {
  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  bool _loading = true;
  bool _error = false;
  List<JournalEntry> _entries = const [];
  JournalStats _stats = const JournalStats();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() {
        _loading = false;
        _entries = const [];
        _stats = const JournalStats();
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _repo.journal(token),
        _repo.journalStats(token),
      ]);
      if (!mounted) return;
      setState(() {
        _entries = results[0] as List<JournalEntry>;
        _stats = results[1] as JournalStats;
        _loading = false;
        _error = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('journal_list'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          PortfolioManagerCard(repository: widget.repository),
          const SizedBox(height: 24),
          const Text('Portfolio Journal',
              key: Key('journal_title'),
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 4),
          const Text(
            'Your research diary of simulated trades. No real broker order is '
            'ever sent.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('Journal unavailable.',
                    style: TextStyle(color: AppColors.down)),
              ),
            )
          else ...[
            if (_entries.isEmpty)
              _JournalEmptyState(repository: widget.repository)
            else ...[
              _StatsCard(stats: _stats),
              const SizedBox(height: 16),
              for (final e in _entries) _JournalCard(entry: e),
            ],
          ],
        ],
      ),
    );
  }
}

/// Mature empty state for the journal: explains *why* it is empty and gives a
/// clear next action instead of showing a blank card.
class _JournalEmptyState extends StatelessWidget {
  const _JournalEmptyState({this.repository});
  final StockRepository? repository;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('journal_empty'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
        child: Column(
          children: [
            Icon(Icons.menu_book_outlined,
                size: 44, color: AppColors.seed.withValues(alpha: 0.7)),
            const SizedBox(height: 14),
            const Text('No trades yet',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 6),
            const Text(
              'Your journal will appear after you place simulated buy/sell '
              'orders.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('journal_empty_cta'),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Go to AI Analysis'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AiAnalysisPage(repository: repository),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats});
  final JournalStats stats;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('journal_stats_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Stats',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 8),
            Row(
              children: [
                _Stat(label: 'Trades', value: '${stats.totalTrades}'),
                _Stat(
                    label: 'Win Rate',
                    value: '${stats.winRate.toStringAsFixed(0)}%'),
                _Stat(label: 'Open', value: '${stats.openPositions}'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _Stat(
                    label: 'Avg Gain',
                    value: '+${stats.averageGain.toStringAsFixed(1)}%',
                    color: AppColors.up),
                _Stat(
                    label: 'Avg Loss',
                    value: '${stats.averageLoss.toStringAsFixed(1)}%',
                    color: AppColors.down),
                _Stat(
                    label: 'Best',
                    value: stats.bestTrade?.symbol ?? '\u2014'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 16, color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(color: Colors.grey, fontSize: 11)),
        ],
      ),
    );
  }
}

class _JournalCard extends StatelessWidget {
  const _JournalCard({required this.entry});
  final JournalEntry entry;

  @override
  Widget build(BuildContext context) {
    final ret = entry.realizedReturn;
    final retColor =
        (ret ?? 0) >= 0 ? AppColors.up : AppColors.down;
    return Card(
      key: Key('journal_entry_${entry.symbol}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${entry.market.flag} ${entry.symbol}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: entry.isClosed
                        ? Colors.grey.withValues(alpha: 0.15)
                        : AppColors.up.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(entry.status,
                      style: TextStyle(
                          color:
                              entry.isClosed ? Colors.grey : AppColors.up,
                          fontWeight: FontWeight.w700,
                          fontSize: 10)),
                ),
                const Spacer(),
                if (ret != null)
                  Text(
                    '${ret >= 0 ? '+' : ''}${ret.toStringAsFixed(1)}%',
                    style: TextStyle(
                        color: retColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 15),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _kv('Score', entry.score.toStringAsFixed(0)),
                _kv('Signal', entry.signal),
                _kv('Radar Rank',
                    entry.radarRank == null ? '\u2014' : '#${entry.radarRank}'),
                _kv('Health',
                    entry.portfolioHealth.toStringAsFixed(0)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$k: ',
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
        Text(v,
            style:
                const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
      ],
    );
  }
}
