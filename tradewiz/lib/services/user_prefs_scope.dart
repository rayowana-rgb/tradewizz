import 'package:flutter/widgets.dart';

import 'user_prefs_store.dart';

/// Exposes the app-wide [UserPrefsStore] to the widget tree and rebuilds
/// dependents when personalization changes (Phase A/B).
class UserPrefsScope extends InheritedNotifier<UserPrefsStore> {
  const UserPrefsScope({
    super.key,
    required UserPrefsStore store,
    required super.child,
  }) : super(notifier: store);

  static UserPrefsStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<UserPrefsScope>();
    assert(scope != null, 'No UserPrefsScope found in context');
    return scope!.notifier!;
  }

  static UserPrefsStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UserPrefsScope>()?.notifier;
}
