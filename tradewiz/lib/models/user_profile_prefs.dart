import 'market.dart';

extension _Let<T> on T {
  R let<R>(R Function(T) op) => op(this);
}

/// User investing interests captured during onboarding (Phase A, screen 3).
///
/// These are personalization hints only — they tune ranking/labelling of the
/// home experience. They never change the backend scoring engines.
enum Interest {
  growth('growth', 'Growth Stocks'),
  dividend('dividend', 'Dividend Stocks'),
  value('value', 'Value Investing'),
  swing('swing', 'Swing Trading'),
  momentum('momentum', 'Momentum'),
  multibagger('multibagger', 'Multibaggers'),
  etf('etf', 'ETFs'),
  global('global', 'Global Markets');

  const Interest(this.code, this.label);
  final String code;
  final String label;

  static Interest? fromCode(String? code) {
    if (code == null) return null;
    for (final i in Interest.values) {
      if (i.code == code) return i;
    }
    return null;
  }
}

/// Locally-stored personalization profile (Phase A). Additive: it does not
/// replace the auth [UserProfile]; it only records onboarding preferences that
/// drive the personalized home screen + Today's Ideas ranking.
class UserPrefs {
  const UserPrefs({
    this.markets = const [],
    this.interests = const [],
    this.onboarded = false,
    this.displayName = '',
    this.completedAt,
    this.preferredBrokerId,
    this.holdingsCollapsed = false,
    this.tradesCollapsed = false,
    this.managerRecsCollapsed = false,
  });

  /// Markets the user picked (screen 2). Empty => not yet chosen.
  final List<Market> markets;

  /// Investing interests (screen 3).
  final List<Interest> interests;

  /// Whether the onboarding flow was completed at least once.
  final bool onboarded;

  /// Optional first name for the `Good Morning <name>` hero greeting.
  final String displayName;

  final DateTime? completedAt;

  /// Stable id of the user's preferred broker app (see [BrokerApp]). Null when
  /// not yet chosen — the broker picker then shows all options with no default.
  /// Persisted locally only; it never affects scoring or trading.
  final String? preferredBrokerId;

  /// Whether the Account page Holdings / Trade History sections are collapsed.
  /// User-facing space-saving toggle; persisted locally only. Default false
  /// (expanded). They never affect data, scoring, or trading.
  final bool holdingsCollapsed;
  final bool tradesCollapsed;

  /// Whether the AI Portfolio Manager "Recommendations" section is hidden.
  /// User-facing space-saving toggle; persisted locally only. Default false
  /// (shown). Never affects data, scoring, or trading.
  final bool managerRecsCollapsed;

  /// The market the home screen should lead with (first selected, else IDX).
  Market get primaryMarket => markets.isEmpty ? Market.idx : markets.first;

  bool get hasInterest => interests.isNotEmpty;

  bool likes(Interest i) => interests.contains(i);

  UserPrefs copyWith({
    List<Market>? markets,
    List<Interest>? interests,
    bool? onboarded,
    String? displayName,
    DateTime? completedAt,
    String? preferredBrokerId,
    bool clearPreferredBroker = false,
    bool? holdingsCollapsed,
    bool? tradesCollapsed,
    bool? managerRecsCollapsed,
  }) =>
      UserPrefs(
        markets: markets ?? this.markets,
        interests: interests ?? this.interests,
        onboarded: onboarded ?? this.onboarded,
        displayName: displayName ?? this.displayName,
        completedAt: completedAt ?? this.completedAt,
        preferredBrokerId: clearPreferredBroker
            ? null
            : (preferredBrokerId ?? this.preferredBrokerId),
        holdingsCollapsed: holdingsCollapsed ?? this.holdingsCollapsed,
        tradesCollapsed: tradesCollapsed ?? this.tradesCollapsed,
        managerRecsCollapsed:
            managerRecsCollapsed ?? this.managerRecsCollapsed,
      );

  Map<String, dynamic> toJson() => {
        'markets': markets.map((m) => m.code).toList(),
        'interests': interests.map((i) => i.code).toList(),
        'onboarded': onboarded,
        'display_name': displayName,
        'completed_at': completedAt?.toIso8601String(),
        'preferred_broker_id': preferredBrokerId,
        'holdings_collapsed': holdingsCollapsed,
        'trades_collapsed': tradesCollapsed,
        'manager_recs_collapsed': managerRecsCollapsed,
      };

  factory UserPrefs.fromJson(Map<String, dynamic> j) => UserPrefs(
        markets: (j['markets'] as List<dynamic>? ?? [])
            .map((e) => Market.fromCode(e.toString()))
            .toList(),
        interests: (j['interests'] as List<dynamic>? ?? [])
            .map((e) => Interest.fromCode(e.toString()))
            .whereType<Interest>()
            .toList(),
        onboarded: j['onboarded'] == true,
        displayName: (j['display_name'] ?? '').toString(),
        completedAt: j['completed_at'] == null
            ? null
            : DateTime.tryParse(j['completed_at'].toString()),
        preferredBrokerId: (j['preferred_broker_id'] as String?)
            ?.let((s) => s.isEmpty ? null : s),
        holdingsCollapsed: j['holdings_collapsed'] == true,
        tradesCollapsed: j['trades_collapsed'] == true,
        managerRecsCollapsed: j['manager_recs_collapsed'] == true,
      );
}
