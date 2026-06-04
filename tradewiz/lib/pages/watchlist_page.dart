import 'package:flutter/material.dart';

import '../models/market.dart';
import '../models/watchlist_item.dart';
import '../services/watchlist_scope.dart';

/// Watchlist for the selected market, backed by the shared [WatchlistStore].
class WatchlistPage extends StatelessWidget {
  const WatchlistPage({super.key, required this.market});

  final Market market;

  @override
  Widget build(BuildContext context) {
    final store = WatchlistScope.of(context); // rebuilds on changes
    final items = store.forMarket(market);

    if (items.isEmpty) {
      return _EmptyWatchlist(market: market);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Card(
          child: Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                Dismissible(
                  key: ValueKey('${items[i].market.code}:${items[i].symbol}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    color: Colors.red.shade50,
                    child: const Icon(Icons.delete_outline, color: Colors.red),
                  ),
                  onDismissed: (_) =>
                      store.remove(items[i].symbol, items[i].market),
                  child: _WatchlistTile(item: items[i]),
                ),
                if (i != items.length - 1)
                  const Divider(height: 1, indent: 72),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            'Swipe left to remove · ${items.length} in watchlist',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _WatchlistTile extends StatelessWidget {
  const _WatchlistTile({required this.item});
  final WatchlistItem item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primary.withValues(
              alpha: 0.1,
            ),
        child: Text(
          item.symbol.characters.take(2).toString(),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
      title: Text(
        item.symbol,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        item.name.isEmpty ? item.market.name : item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        '${item.market.flag} ${item.market.code}',
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      ),
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
