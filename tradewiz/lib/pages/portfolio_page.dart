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
      if (!mounted) return;
      setState(() => _portfolio = p);
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
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Summary'),
              Tab(text: 'Positions'),
              Tab(text: 'Orders'),
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
                    fontSize: 18,
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
