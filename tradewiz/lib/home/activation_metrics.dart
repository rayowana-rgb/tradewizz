import 'package:flutter/foundation.dart';

/// Phase I — activation/retention funnel instrumentation.
///
/// In-memory counters + a best-effort backend sink. Additive and non-blocking:
/// a tracking failure must never affect the UI. The named events mirror the
/// Phase I success-metrics list.
class ActivationMetrics extends ChangeNotifier {
  ActivationMetrics({this.sink});

  /// Optional backend sink (e.g. repository.recordPreviewEvent). Best-effort.
  final Future<void> Function(String event, {String meta})? sink;

  final Map<String, int> _counts = {};

  Map<String, int> snapshot() => Map.unmodifiable(_counts);
  int count(String event) => _counts[event] ?? 0;

  void _emit(String event, {String meta = ''}) {
    _counts[event] = (_counts[event] ?? 0) + 1;
    notifyListeners();
    final s = sink;
    if (s != null) s(event, meta: meta).catchError((_) {});
  }

  // --- Funnel events -------------------------------------------------------

  /// User opened the onboarding flow (screen 1).
  void onboardingStarted() => _emit('onboarding_started');

  /// User finished onboarding (after the first brief generated).
  void onboardingCompleted({int markets = 0, int interests = 0}) =>
      _emit('onboarding_completed', meta: 'm=$markets;i=$interests');

  /// User created their first watchlist during onboarding (>=3 symbols).
  void firstWatchlistCreated(int size) =>
      _emit('first_watchlist_created', meta: 'n=$size');

  /// The personalized first Morning Brief was generated (Time To First Value).
  void firstValueDelivered() => _emit('time_to_first_value');

  /// User opened / viewed a Morning Brief (drives Morning Brief Open Rate).
  void morningBriefOpened() => _emit('morning_brief_opened');

  /// Home screen viewed (Daily Active signal).
  void homeViewed() => _emit('home_viewed');

  /// User tapped an idea in Today's Ideas (engagement).
  void ideaTapped(String symbol) => _emit('idea_tapped', meta: symbol);

  /// User reached the paywall/upgrade surface (conversion funnel).
  void paywallViewed({String from = ''}) =>
      _emit('paywall_viewed', meta: from);

  /// User converted to a paid (or waitlisted preview) tier.
  void subscriptionConverted(String tier) =>
      _emit('subscription_converted', meta: tier);

  /// Activation = onboarding complete AND first value delivered.
  bool get activated =>
      count('onboarding_completed') > 0 && count('time_to_first_value') > 0;
}
