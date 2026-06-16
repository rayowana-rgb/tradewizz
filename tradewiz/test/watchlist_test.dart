import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/watchlist_item.dart';
import 'package:tradewiz/pages/watchlist_page.dart';
import 'package:tradewiz/services/watchlist_store.dart';

import 'helpers.dart';

/// In-memory persistence that survives across store instances within a test,
/// emulating a relaunch.
class FakePersistence implements WatchlistPersistence {
  List<WatchlistItem> _data = [];

  @override
  Future<List<WatchlistItem>> load() async =>
      _data.map((e) => WatchlistItem.fromJson(e.toJson())).toList();

  @override
  Future<void> save(List<WatchlistItem> items) async {
    _data = items.map((e) => WatchlistItem.fromJson(e.toJson())).toList();
  }
}

void main() {
  test('store persists adds and survives a relaunch', () async {
    final backend = FakePersistence();

    final store = WatchlistStore(persistence: backend);
    await store.load(); // first launch: seeds sample data + saves
    expect(store.items, isNotEmpty);

    store.add(const WatchlistItem(
      symbol: 'TEST',
      name: 'Test Co.',
      market: Market.idx,
    ));
    await Future<void>.delayed(Duration.zero); // let async save flush
    expect(store.contains('TEST', Market.idx), isTrue);

    // "Relaunch": a fresh store backed by the same persistence.
    final reopened = WatchlistStore(persistence: backend);
    await reopened.load();
    expect(reopened.contains('TEST', Market.idx), isTrue);
  });

  test('removal is persisted across relaunch', () async {
    final backend = FakePersistence();
    final store = WatchlistStore(persistence: backend);
    await store.load();

    final first = store.items.first;
    store.remove(first.symbol, first.market);
    await Future<void>.delayed(Duration.zero);

    final reopened = WatchlistStore(persistence: backend);
    await reopened.load();
    expect(reopened.contains(first.symbol, first.market), isFalse);
  });

  testWidgets('Tapping a watchlist row opens its analysis', (tester) async {
    final store = WatchlistStore(seed: true);

    await tester.pumpWidget(
      wrapApp(const WatchlistPage(market: Market.idx), store: store),
    );
    await tester.pumpAndSettle();

    // Tap the first IDX symbol row.
    final firstIdx =
        store.forMarket(Market.idx).first.symbol;
    await tester.tap(find.text(firstIdx));
    await tester.pump(); // navigation
    await tester.pump(); // autoRun post-frame
    await tester.pump(const Duration(seconds: 1)); // mocked latency
    await tester.pumpAndSettle();

    // Detail page app-bar title + analysis result rendered.
    expect(find.text('$firstIdx · IDX'), findsOneWidget);
    expect(find.textContaining('Score'), findsOneWidget);
  });

  testWidgets(
      'cross-market picks (e.g. Auto Watchlist AI) show under Other Markets '
      'on a different market tab', (tester) async {
    // Empty store + one US name, as if Apply All added a US pick while the
    // user is on the IDX tab. It must still be visible, not silently hidden.
    final store = WatchlistStore();
    store.add(const WatchlistItem(
      symbol: 'ROKU',
      name: 'Roku Inc.',
      market: Market.us,
    ));

    await tester.pumpWidget(
      wrapApp(const WatchlistPage(market: Market.idx), store: store),
    );
    await tester.pumpAndSettle();

    // Not in the current-market list, but surfaced in Other Markets.
    expect(find.byKey(const Key('watchlist_other_markets')), findsOneWidget);
    expect(find.text('ROKU'), findsOneWidget);
    expect(find.text('Other Markets'), findsOneWidget);
  });
}
