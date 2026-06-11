import 'package:flutter/material.dart';

import '../models/portfolio.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';

/// Portfolio tab with Summary / Positions / Orders sub-tabs. Aggregates across
/// the user's connected brokers via GET /v1/portfolio. Requires sign-in.
class PortfolioPage extends StatefulWidget {
  const PortfolioPage({super.key, this.repository});

  final StockRepository? repository;

  @override
  State<PortfolioPage> createState() => _PortfolioPageState();
}

class _PortfolioPageState extends State<PortfolioPage> {
  bool _loading = false;
  String? _error;
  UnifiedPortfolio? _portfolio;
  PortfolioPerformance? _performance;

  StockRepository get _repo => widget.repository ?? RepositoryScope.of(context);
  String? get _token => AuthScope.of(context).token;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_token != null && _portfolio == null && !_loading) {
      _load();
    }
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await _repo.portfolio(token);
      final perf = await _repo.portfolioPerformance(token);
      if (!mounted) return;
      setState(() {
        _portfolio = p;
        _performance = perf;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context); // rebuild on login/logout
    if (!auth.isLoggedIn) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Sign in (Account tab) to view your portfolio.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Summary'),
              Tab(text: 'Positions'),
              Tab(text: 'Orders'),
              Tab(text: 'Performance'),
            ],
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _ErrorView(message: _error!, onRetry: _load)
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: TabBarView(
                          children: [
                            _SummaryTab(portfolio: _portfolio),
                            _PositionsTab(portfolio: _portfolio),
                            const _OrdersTab(),
                            _PerformanceTab(performance: _performance),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _SummaryTab extends StatelessWidget {
  const _SummaryTab({required this.portfolio});
  final UnifiedPortfolio? portfolio;

  @override
  Widget build(BuildContext context) {
    final s = portfolio?.summary ?? const PortfolioSummary();
    final brokers = portfolio?.brokers ?? const <String>[];
    final errors = portfolio?.errors ?? const <PortfolioBrokerError>[];
    Widget tile(String label, double value, {Color? color, Key? key}) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 4),
                Text(
                  value.toStringAsFixed(2),
                  key: key,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        );
    final pnlColor =
        s.floatingPnl >= 0 ? AppColors.up : AppColors.down;
    final realizedColor =
        s.realizedPnl >= 0 ? AppColors.up : AppColors.down;
    // Mature empty state: no broker connected yet. Explain the current
    // (simulation-only) reality instead of showing zeroed-out tiles.
    if (brokers.isEmpty) {
      return ListView(
        key: const Key('broker_empty'),
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
        children: [
          Icon(Icons.account_balance_outlined,
              size: 44, color: AppColors.seed.withValues(alpha: 0.7)),
          const SizedBox(height: 14),
          const Text('Broker connection is not enabled yet',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 6),
          const Text(
            'For now, TradeWizz uses simulated portfolio tracking.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('broker_empty_cta'),
              icon: const Icon(Icons.show_chart),
              label: const Text('Use Simulation Portfolio'),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          const SizedBox(height: 10),
          const Center(
            child: Text('Broker linking — coming soon',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        tile('Total Equity', s.totalEquity, key: const Key('total_equity')),
        tile('Cash', s.cash, key: const Key('cash')),
        tile('Buying Power', s.buyingPower),
        tile('Market Value', s.marketValue),
        tile('Floating P/L', s.floatingPnl,
            color: pnlColor, key: const Key('floating_pnl')),
        tile('Realized P/L', s.realizedPnl,
            color: realizedColor, key: const Key('realized_pnl')),
        const SizedBox(height: 8),
        Text(
          brokers.isEmpty
              ? 'No brokers connected. Connect one from Account → Broker '
                  'Connections.'
              : 'Aggregated from: ${brokers.join(', ')}',
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
        if (errors.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final e in errors)
            Card(
              key: Key('portfolio_error_${e.broker}'),
              color: AppColors.down.withValues(alpha: 0.06),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 18, color: AppColors.down),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('${e.broker}: ${e.message}',
                        style: const TextStyle(
                            color: AppColors.down, fontSize: 12)),
                  ),
                ]),
              ),
            ),
        ],
      ],
    );
  }
}

class _PositionsTab extends StatelessWidget {
  const _PositionsTab({required this.portfolio});
  final UnifiedPortfolio? portfolio;

  @override
  Widget build(BuildContext context) {
    final positions = portfolio?.positions ?? const <PortfolioPosition>[];
    if (positions.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 80),
          Center(
            child: Text('No open positions.',
                style: TextStyle(color: Colors.grey)),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: positions.length,
      separatorBuilder: (_, index) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final p = positions[i];
        final up = p.unrealizedPnl >= 0;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text('${p.symbol}  ·  ${p.broker}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Text(
                    '${up ? '+' : ''}${p.unrealizedPnl.toStringAsFixed(2)}',
                    style: TextStyle(
                        color: up ? AppColors.up : AppColors.down,
                        fontWeight: FontWeight.w700),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                  'Qty ${p.quantity.toStringAsFixed(0)} · avg '
                  '${p.averageCost.toStringAsFixed(2)} · last '
                  '${p.currentPrice.toStringAsFixed(2)} · value '
                  '${p.marketValue.toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _OrdersTab extends StatelessWidget {
  const _OrdersTab();

  @override
  Widget build(BuildContext context) {
    // Orders are broker-specific; the unified orders view is a future step.
    return ListView(
      children: const [
        SizedBox(height: 80),
        Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Order history per broker is available on each broker.\n'
              'A unified orders view is coming soon.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
      ],
    );
  }
}

class _PerformanceTab extends StatelessWidget {
  const _PerformanceTab({required this.performance});
  final PortfolioPerformance? performance;

  @override
  Widget build(BuildContext context) {
    final p = performance ?? const PortfolioPerformance();
    Color pnlColor(double v) => v >= 0 ? AppColors.up : AppColors.down;
    String money(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';

    Widget metric(String label, double v, {String? key, bool pct = false}) =>
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(
                    pct ? '${money(v)}%' : money(v),
                    key: key == null ? null : Key(key),
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: pnlColor(v)),
                  ),
                ],
              ),
            ),
          ),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Row(children: [
          metric('Total P/L', p.totalPnl, key: 'perf_total_pnl'),
          const SizedBox(width: 10),
          metric('Daily P/L', p.dailyPnl, key: 'perf_daily_pnl'),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          metric('Floating P/L', p.floatingPnl, key: 'perf_floating_pnl'),
          const SizedBox(width: 10),
          metric('Realized P/L', p.realizedPnl, key: 'perf_realized_pnl'),
        ]),
        for (final note in p.notes)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(note,
                key: note.startsWith('Realized')
                    ? const Key('realized_note')
                    : null,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ),

        const SizedBox(height: 16),
        const _SectionLabel('Broker Breakdown'),
        if (p.brokerBreakdown.isEmpty)
          const _Muted('No broker data.')
        else
          for (final b in p.brokerBreakdown)
            Card(
              key: Key('broker_bd_${b.broker}'),
              child: ListTile(
                title: Text(b.broker,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                    'Value ${b.marketValue.toStringAsFixed(2)} · '
                    'Floating ${money(b.floatingPnl)}'),
              ),
            ),

        const SizedBox(height: 16),
        const _SectionLabel('Top Winners'),
        if (p.topWinners.isEmpty)
          const _Muted('No winners yet.')
        else
          for (final w in p.topWinners)
            _PnlRow(item: w, up: true),

        const SizedBox(height: 16),
        const _SectionLabel('Top Losers'),
        if (p.topLosers.isEmpty)
          const _Muted('No losers yet.')
        else
          for (final l in p.topLosers)
            _PnlRow(item: l, up: false),

        const SizedBox(height: 16),
        const _SectionLabel('Equity Curve'),
        if (!p.hasHistory)
          const _Muted('No performance history yet.')
        else
          Card(
            child: Column(
              children: [
                for (final pt in p.equityCurve)
                  ListTile(
                    dense: true,
                    title: Text(pt.timestamp.split('T').first),
                    trailing: Text(pt.totalEquity.toStringAsFixed(2),
                        style:
                            const TextStyle(fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style:
                const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      );
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text, style: const TextStyle(color: Colors.grey)),
      );
}

class _PnlRow extends StatelessWidget {
  const _PnlRow({required this.item, required this.up});
  final PositionPnL item;
  final bool up;
  @override
  Widget build(BuildContext context) {
    final color = up ? AppColors.up : AppColors.down;
    return Card(
      child: ListTile(
        dense: true,
        title: Text('${item.symbol}  ·  ${item.broker}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: Text(
          '${item.unrealizedPnl >= 0 ? '+' : ''}'
          '${item.unrealizedPnl.toStringAsFixed(2)}  '
          '(${item.unrealizedPnlPercent.toStringAsFixed(2)}%)',
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: AppColors.down),
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
