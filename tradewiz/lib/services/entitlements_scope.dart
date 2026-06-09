import 'package:flutter/widgets.dart';

import '../models/subscription.dart';
import '../repositories/stock_repository.dart';

/// Holds the current user's entitlements and reloads them when the session
/// token changes. Defaults to FREE so the UI can render before/without a
/// network response. Logged-out users are always treated as FREE.
class EntitlementsStore extends ChangeNotifier {
  EntitlementsStore({required StockRepository repository})
      // ignore: prefer_initializing_formals
      : _repository = repository;
  final StockRepository _repository;

  Entitlements _entitlements = Entitlements.free;
  String? _loadedForToken;
  bool _loading = false;

  Entitlements get entitlements => _entitlements;
  Tier get tier => _entitlements.tier;
  bool get loading => _loading;

  bool has(String feature) => _entitlements.has(feature);
  bool atLeast(Tier t) => _entitlements.tier.atLeast(t);

  /// Load entitlements for [token]. A null token resets to FREE. Best-effort:
  /// a failure keeps the last-known (or FREE) state without throwing.
  Future<void> refresh(String? token) async {
    if (token == null) {
      _loadedForToken = null;
      if (_entitlements.tier != Tier.free) {
        _entitlements = Entitlements.free;
        notifyListeners();
      }
      return;
    }
    if (_loading) return;
    _loading = true;
    notifyListeners();
    try {
      final ent = await _repository.entitlements(token);
      _entitlements = ent;
      _loadedForToken = token;
    } catch (_) {
      // Keep prior state; gating fails safe (closed) toward FREE on first load.
      if (_loadedForToken == null) _entitlements = Entitlements.free;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Sync the store to the active token, loading once per new token.
  void syncToken(String? token) {
    if (token == _loadedForToken) return;
    refresh(token);
  }
}

/// Provides [EntitlementsStore] to the widget tree; rebuilds dependents on
/// change. Lookups are optional-safe (no assert) so pages outside the scope
/// (e.g. some tests) simply see FREE.
class EntitlementsScope extends InheritedNotifier<EntitlementsStore> {
  const EntitlementsScope({
    super.key,
    required EntitlementsStore store,
    required super.child,
  }) : super(notifier: store);

  static EntitlementsStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EntitlementsScope>()?.notifier;

  /// Current entitlements, or FREE when no scope is present.
  static Entitlements entitlements(BuildContext context) =>
      maybeOf(context)?.entitlements ?? Entitlements.free;
}
