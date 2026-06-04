import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/market.dart';
import '../models/stock.dart';
import '../models/watchlist_item.dart';

/// Abstraction over persistence so the store can be tested without a real
/// SharedPreferences backend.
abstract class WatchlistPersistence {
  Future<List<WatchlistItem>> load();
  Future<void> save(List<WatchlistItem> items);
}

/// SharedPreferences-backed persistence.
class SharedPrefsWatchlistPersistence implements WatchlistPersistence {
  static const _key = 'tradewiz.watchlist.v1';

  @override
  Future<List<WatchlistItem>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => WatchlistItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<WatchlistItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(items.map((e) => e.toJson()).toList());
    await prefs.setString(_key, raw);
  }
}

/// App-wide watchlist store backed by [WatchlistPersistence].
///
/// A [ChangeNotifier] so any widget can listen and rebuild when items change.
class WatchlistStore extends ChangeNotifier {
  WatchlistStore({this.persistence, bool seed = false}) {
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

  final WatchlistPersistence? persistence;
  final List<WatchlistItem> _items = [];

  bool _loaded = false;
  bool get isLoaded => _loaded;

  List<WatchlistItem> get items => List.unmodifiable(_items);

  List<WatchlistItem> forMarket(Market market) =>
      _items.where((i) => i.market == market).toList();

  bool contains(String symbol, Market market) => _items.any(
        (i) => i.symbol == symbol.toUpperCase() && i.market == market,
      );

  /// Loads persisted items once. Seeds with sample data on first ever launch
  /// (no persisted entries yet) so the app isn't empty out of the box.
  Future<void> load() async {
    final p = persistence;
    if (_loaded || p == null) {
      _loaded = true;
      return;
    }
    final stored = await p.load();
    if (stored.isNotEmpty) {
      _items
        ..clear()
        ..addAll(stored);
    } else if (_items.isEmpty) {
      _items.addAll(sampleStocks.map((s) => WatchlistItem(
            symbol: s.ticker,
            name: s.name,
            market: s.market,
            addedAt: DateTime.now(),
          )));
      await p.save(_items);
    }
    _loaded = true;
    notifyListeners();
  }

  /// Adds an item. Returns false if it was already present.
  bool add(WatchlistItem item) {
    final normalized = item.symbol.toUpperCase();
    if (contains(normalized, item.market)) return false;
    _items.add(WatchlistItem(
      symbol: normalized,
      name: item.name,
      market: item.market,
      addedAt: item.addedAt ?? DateTime.now(),
    ));
    notifyListeners();
    _persist();
    return true;
  }

  void remove(String symbol, Market market) {
    _items.removeWhere(
      (i) => i.symbol == symbol.toUpperCase() && i.market == market,
    );
    notifyListeners();
    _persist();
  }

  void _persist() {
    persistence?.save(_items);
  }
}
