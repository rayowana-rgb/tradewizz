import 'package:flutter/material.dart';

import '../models/market.dart';
import '../models/stock.dart';
import '../theme.dart';
import '../widgets/stock_tile.dart';

/// Clean overview: market summary cards + top movers for the selected market.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.market});

  final Market market;

  @override
  Widget build(BuildContext context) {
    final stocks =
        sampleStocks.where((s) => s.market == market).toList();
    final gainers = [...stocks]
      ..sort((a, b) => b.changePercent.compareTo(a.changePercent));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
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
                label: 'Listed',
                value: '${stocks.length} tracked',
                sub: 'Sample data',
                subColor: Colors.grey,
                icon: Icons.list_alt,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const _SectionTitle('Top Movers'),
        const SizedBox(height: 8),
        if (gainers.isEmpty)
          const _EmptyState(message: 'No sample data for this market yet.')
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < gainers.length; i++) ...[
                  StockTile(stock: gainers[i]),
                  if (i != gainers.length - 1)
                    const Divider(height: 1, indent: 72),
                ],
              ],
            ),
          ),
      ],
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
