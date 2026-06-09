import '../models/phase2.dart';
import '../snapshot/snapshot_models.dart';
import 'todays_ideas.dart';

/// A push notification the app would send to bring the user back (Phase G).
class RetentionPush {
  const RetentionPush({required this.title, required this.body});
  final String title;
  final String body;
}

/// Phase G — Daily Retention Loop copy generator.
///
/// Pure function: given the freshly generated snapshot + the user's prior
/// watchlist performance, produce the single most compelling "come back" push.
/// The actual scheduling/delivery is the platform's job; this is the messaging
/// brain so it can be unit-tested and reused by a scheduler/FCM later. It never
/// fetches data and never mutates state.
class RetentionNotifications {
  const RetentionNotifications._();

  /// The default daily "your brief is ready" nudge at market open.
  static const RetentionPush morningBriefReady = RetentionPush(
    title: 'Your Morning Brief is ready',
    body: 'See what matters for your stocks today.',
  );

  /// Pick the best push for [snapshot]. Priority:
  ///   1. A new BUY signal on a watchlist symbol.
  ///   2. Yesterday's watchlist gain (when positive and provided).
  ///   3. A new high-scoring idea entering Today's Ideas.
  ///   4. Fallback: the generic "brief is ready".
  static RetentionPush forSnapshot(
    DashboardSnapshot snapshot, {
    List<String> watchlist = const [],
    double? watchlistChangePct,
  }) {
    final wl = watchlist.map((s) => s.toUpperCase()).toSet();
    final ideas = TodaysIdeas.fromSnapshot(snapshot).ideas;

    // 1) Watchlist symbol triggered a BUY signal.
    for (final idea in ideas) {
      if (wl.contains(idea.symbol.toUpperCase()) &&
          idea.signal.toUpperCase().contains('BUY')) {
        return RetentionPush(
          title: '${idea.symbol} triggered a new buy signal',
          body: idea.reason.isEmpty
              ? 'Open TradeWizz to see the analysis.'
              : idea.reason,
        );
      }
    }

    // 2) Watchlist gained yesterday.
    if (watchlistChangePct != null && watchlistChangePct > 0) {
      return RetentionPush(
        title: 'Your watchlist gained '
            '+${watchlistChangePct.toStringAsFixed(1)}% yesterday',
        body: 'See today\'s ideas in your Morning Brief.',
      );
    }

    // 3) A strong new idea entered Today's Ideas.
    if (ideas.isNotEmpty && ideas.first.score >= 80) {
      final top = ideas.first;
      return RetentionPush(
        title: '${top.symbol} entered Today\'s Ideas',
        body: top.reason.isEmpty
            ? 'A new high-conviction opportunity is live.'
            : top.reason,
      );
    }

    // 4) Generic.
    return morningBriefReady;
  }

  /// Convenience: derive a push directly from a [MorningBrief] when no full
  /// snapshot is available.
  static RetentionPush forBrief(MorningBrief? brief) {
    final o = brief?.topOpportunity;
    if (o != null && o.signal.toUpperCase().contains('BUY')) {
      return RetentionPush(
        title: '${o.symbol} triggered a new buy signal',
        body: o.reason.isEmpty ? 'Open your Morning Brief.' : o.reason,
      );
    }
    return morningBriefReady;
  }
}
