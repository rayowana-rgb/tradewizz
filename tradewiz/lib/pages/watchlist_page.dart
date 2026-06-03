import 'package:flutter/material.dart';

import '../models/market.dart';
import '../models/stock.dart';
import '../widgets/stock_tile.dart';

/// Watchlist for the selected market. Local state only (placeholder).
class WatchlistPage extends StatefulWidget {
  const WatchlistPage({super.key, required this.market});

  final Market market;

  @override
  State<WatchlistPage> createState() => _WatchlistPageState();
}

class _WatchlistPageState extends State<WatchlistPage> {
  final Set<String> _removed = {};

  @override
  Widget build(BuildContext context) {
    final stocks = sampleStocks
        .where((s) => s.market == widget.market && !_removed.contains(s.ticker))
        .toList();

    if (stocks.isEmpty) {
      return _EmptyWatchlist(market: widget.market);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Card(
          child: Column(
            children: [
              for (var i = 0; i < stocks.length; i++) ...[
                Dismissible(
                  key: ValueKey(stocks[i].ticker),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    color: Colors.red.shade50,
                    child: const Icon(Icons.delete_outline, color: Colors.red),
                  ),
                  onDismissed: (_) =>
                      setState(() => _removed.add(stocks[i].ticker)),
                  child: StockTile(stock: stocks[i]),
                ),
                if (i != stocks.length - 1)
                  const Divider(height: 1, indent: 72),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            'Swipe left to remove · ${stocks.length} in watchlist',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _EmptyWatchlist extends StatelessWidget {
  const _EmptyWatchlist({required this.market});
  final Market market;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_outline, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          Text(
            'Your ${market.code} watchlist is empty',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Add stocks to track them here.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
