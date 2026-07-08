import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the device screen awake for the duration of a critical, potentially
/// long-running task — most importantly a LIVE order run (bulk buy, momentum
/// basket, or trim). Placing many orders is paced (Moomoo throttles to ~15
/// orders / 30s), so a large run can take several minutes. If the screen
/// switches off during that window the OS can suspend the app and the run is
/// abandoned half-way, leaving some orders placed and others not.
///
/// Holding a wakelock keeps the app foregrounded and the run alive. The lock is
/// always released in a `finally`, and nested runs are reference-counted so an
/// inner task never drops a lock an outer task still needs.
///
/// This is a best-effort convenience, not a background daemon: it does not run
/// while the user hard-backgrounds the app. It only prevents the *screen
/// auto-off* from killing an in-progress run the user started.
class KeepAwake {
  KeepAwake._();

  static int _depth = 0;

  /// Overridable for tests (the plugin needs platform channels). When null the
  /// real `wakelock_plus` plugin is used.
  @visibleForTesting
  static Future<void> Function(bool enable)? debugToggle;

  static Future<void> _set(bool enable) async {
    final override = debugToggle;
    if (override != null) {
      await override(enable);
      return;
    }
    try {
      await WakelockPlus.toggle(enable: enable);
    } catch (_) {
      // Wakelock is a convenience; never let it break the actual task.
    }
  }

  /// Runs [action] with the screen held awake. Reference-counted so concurrent
  /// or nested guarded sections coalesce into a single wakelock.
  static Future<T> guard<T>(Future<T> Function() action) async {
    _depth++;
    if (_depth == 1) {
      await _set(true);
    }
    try {
      return await action();
    } finally {
      _depth--;
      if (_depth <= 0) {
        _depth = 0;
        await _set(false);
      }
    }
  }
}
