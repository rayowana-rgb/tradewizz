import 'package:flutter/widgets.dart';

import 'watchlist_store.dart';

/// Provides a [WatchlistStore] to the widget tree and rebuilds dependents
/// when it changes. Lightweight alternative to a DI package.
class WatchlistScope extends InheritedNotifier<WatchlistStore> {
  const WatchlistScope({
    super.key,
    required WatchlistStore store,
    required super.child,
  }) : super(notifier: store);

  static WatchlistStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<WatchlistScope>();
    assert(scope?.notifier != null, 'No WatchlistScope found in context');
    return scope!.notifier!;
  }

  /// Like [of] but returns null when no scope is present (e.g. onboarding
  /// rendered in isolation in tests).
  static WatchlistStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WatchlistScope>()?.notifier;

  /// Read without subscribing to rebuilds (for one-off actions like add).
  static WatchlistStore read(BuildContext context) {
    final scope = context
        .getInheritedWidgetOfExactType<WatchlistScope>();
    assert(scope?.notifier != null, 'No WatchlistScope found in context');
    return scope!.notifier!;
  }
}
