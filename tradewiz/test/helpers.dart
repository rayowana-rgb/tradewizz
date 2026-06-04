import 'package:flutter/material.dart';

import 'package:tradewiz/services/watchlist_scope.dart';
import 'package:tradewiz/services/watchlist_store.dart';

/// Wraps [child] in a MaterialApp + WatchlistScope for widget tests.
Widget wrapApp(Widget child, {WatchlistStore? store, bool seed = false}) {
  return WatchlistScope(
    store: store ?? WatchlistStore(seed: seed),
    child: MaterialApp(home: Scaffold(body: child)),
  );
}
