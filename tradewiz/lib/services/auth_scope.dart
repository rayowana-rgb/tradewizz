import 'package:flutter/widgets.dart';

import 'auth_store.dart';

/// Provides an [AuthStore] to the widget tree and rebuilds dependents on change.
class AuthScope extends InheritedNotifier<AuthStore> {
  const AuthScope({
    super.key,
    required AuthStore store,
    required super.child,
  }) : super(notifier: store);

  static AuthStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AuthScope>();
    assert(scope?.notifier != null, 'No AuthScope found in context');
    return scope!.notifier!;
  }

  static AuthStore read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AuthScope>();
    assert(scope?.notifier != null, 'No AuthScope found in context');
    return scope!.notifier!;
  }
}
