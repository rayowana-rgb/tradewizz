import 'package:flutter/foundation.dart';

import '../models/market.dart';
import '../models/stock.dart';
import '../models/watchlist_item.dart';

/// In-memory, app-wide watchlist store.
///
/// A [ChangeNotifier] so any widget can listen and rebuild when items change.
/// Swap the seed/persistence for a real local DB later; the API stays the same.
class WatchlistStore extends ChangeNotifier {
  WatchlistStore({bool seed = true}) {
    if (seed) {
      for (final s in sampleStocks) {
        _items.add(WatchlistItem(
          symbol: s.ticker,
          name: s.name,
          market: s.market,
          addedAt: DateTime.now(),
        ));
      }
    }
  }

  final List<WatchlistItem> _items = [];

  List<WatchlistItem> get items => List.unmodifiable(_items);

  List<WatchlistItem> forMarket(Market market) =>
      _items.where((i) => i.market == market).toList();

  bool contains(String symbol, Market market) => _items.any(
        (i) => i.symbol == symbol.toUpperCase() && i.market == market,
      );

  /// Adds an item. Returns false if it was already present.
  bool add(WatchlistItem item) {
    final normalized = item.copyWith().symbol.toUpperCase();
    if (contains(normalized, item.market)) return false;
    _items.add(WatchlistItem(
      symbol: normalized,
      name: item.name,
      market: item.market,
      addedAt: item.addedAt ?? DateTime.now(),
    ));
    notifyListeners();
    return true;
  }

  void remove(String symbol, Market market) {
    _items.removeWhere(
      (i) => i.symbol == symbol.toUpperCase() && i.market == market,
    );
    notifyListeners();
  }
}
