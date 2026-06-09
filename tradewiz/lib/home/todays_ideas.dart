import '../models/market.dart';
import '../models/phase3.dart';
import '../models/subscription.dart';
import '../models/user_profile_prefs.dart';
import '../snapshot/snapshot_models.dart';

/// The source engine that surfaced an idea. The user never needs to understand
/// which backend engine produced it — they only see a friendly label.
enum IdeaSource {
  momentum('Momentum'),
  value('Value'),
  growth('Growth'),
  aiConviction('AI Conviction'),
  turnaround('Turnaround'),
  multibagger('Multibagger'),
  dailyPick('Daily Pick');

  const IdeaSource(this.label);
  final String label;
}

/// One unified idea (Phase C). Aggregates Daily Picks, Opportunity Radar, Auto
/// Watchlist AI, and the Multibagger Finder into a single ranked entity. The
/// underlying scoring engines are unchanged — this only *merges + ranks* their
/// outputs for presentation.
class TradeIdea {
  const TradeIdea({
    required this.symbol,
    required this.market,
    required this.name,
    required this.score,
    required this.signal,
    required this.reason,
    required this.source,
  });

  final String symbol;
  final Market market;
  final String name;
  final double score;
  final String signal; // BUY / HOLD / SELL / WATCH
  final String reason;
  final IdeaSource source;

  /// De-dupe key: same symbol+market is the same idea regardless of engine.
  String get key => '${market.code}:$symbol';
}

/// Aggregates the four idea engines into one ranked "Today's Ideas" feed.
///
/// Inputs are the *existing* engine outputs (already computed by the backend).
/// We never recompute scores; we only normalize, de-duplicate (keeping the
/// highest-scoring source per symbol), apply a small personalization boost from
/// onboarding interests, and rank.
class TodaysIdeas {
  const TodaysIdeas._(this.ideas);

  /// An empty feed (e.g. before the first snapshot loads).
  const TodaysIdeas.empty() : ideas = const [];

  final List<TradeIdea> ideas;

  bool get isEmpty => ideas.isEmpty;
  int get length => ideas.length;

  List<TradeIdea> top(int n) => ideas.take(n).toList();

  /// Build directly from a [DashboardSnapshot] (offline-first / CDN path).
  factory TodaysIdeas.fromSnapshot(
    DashboardSnapshot snapshot, {
    UserPrefs prefs = const UserPrefs(),
    int limit = 12,
  }) {
    return TodaysIdeas.fromEngines(
      dailyPicks: snapshot.dailyPicks,
      radar: snapshot.radar,
      autoWatchlist: snapshot.watchlistAi,
      multibagger: snapshot.multibagger,
      prefs: prefs,
      limit: limit,
    );
  }

  /// Build from individual engine results (live repo path or tests).
  factory TodaysIdeas.fromEngines({
    DailyPicks? dailyPicks,
    OpportunitiesResult? radar,
    AutoWatchlistSuggestions? autoWatchlist,
    MultibaggerResult? multibagger,
    UserPrefs prefs = const UserPrefs(),
    int limit = 12,
  }) {
    final byKey = <String, _Ranked>{};

    void consider(TradeIdea idea) {
      final boosted = _personalize(idea, prefs);
      final existing = byKey[idea.key];
      // Keep the highest-scoring representation of a symbol across engines.
      if (existing == null || boosted.rank > existing.rank) {
        byKey[idea.key] = boosted;
      }
    }

    // Daily Picks -> "Daily Pick"
    for (final p in dailyPicks?.picks ?? const []) {
      consider(TradeIdea(
        symbol: p.symbol,
        market: p.market,
        name: p.name,
        score: p.score,
        signal: p.signal,
        reason: p.recommendation.isNotEmpty
            ? p.recommendation
            : 'Top-ranked opportunity today.',
        source: IdeaSource.dailyPick,
      ));
    }

    // Opportunity Radar -> labelled by signal/regime
    for (final o in radar?.globalTop10 ?? const []) {
      consider(TradeIdea(
        symbol: o.symbol,
        market: o.market,
        name: o.name,
        score: o.score,
        signal: o.signal,
        reason: o.opportunityReason.isNotEmpty
            ? o.opportunityReason
            : 'Strong opportunity signal detected.',
        source: _sourceForSignal(o.signal, o.marketRegime),
      ));
    }
    for (final o in radar?.multibaggerCandidates ?? const []) {
      consider(TradeIdea(
        symbol: o.symbol,
        market: o.market,
        name: o.name,
        score: o.score,
        signal: o.signal,
        reason: o.opportunityReason.isNotEmpty
            ? o.opportunityReason
            : 'High-upside candidate.',
        source: IdeaSource.multibagger,
      ));
    }

    // Auto Watchlist AI -> mapped by origin
    for (final s in autoWatchlist?.suggestions ?? const []) {
      consider(TradeIdea(
        symbol: s.symbol,
        market: s.market,
        name: s.name,
        score: s.score,
        signal: s.signal,
        reason: s.reason.isNotEmpty ? s.reason : 'AI watchlist pick.',
        source: _sourceForOrigin(s.origin),
      ));
    }

    // Multibagger Finder -> "Multibagger"
    for (final c in multibagger?.candidates ?? const []) {
      consider(TradeIdea(
        symbol: c.symbol,
        market: c.market,
        name: c.name,
        score: c.score,
        signal: 'WATCH',
        reason: c.reason.isNotEmpty ? c.reason : 'Multibagger candidate.',
        source: IdeaSource.multibagger,
      ));
    }

    final ranked = byKey.values.toList()
      ..sort((a, b) => b.rank.compareTo(a.rank));
    final ideas = ranked.map((r) => r.idea).take(limit).toList();
    return TodaysIdeas._(ideas);
  }

  // --- helpers -------------------------------------------------------------

  static IdeaSource _sourceForSignal(String signal, String regime) {
    final s = signal.toUpperCase();
    if (s == 'BUY' || s == 'STRONG_BUY') return IdeaSource.momentum;
    if (regime.toUpperCase().contains('BEAR')) return IdeaSource.turnaround;
    return IdeaSource.aiConviction;
  }

  static IdeaSource _sourceForOrigin(String origin) {
    switch (origin.toUpperCase()) {
      case 'MULTIBAGGER':
        return IdeaSource.multibagger;
      case 'DAILY_PICKS':
      case 'DAILY':
        return IdeaSource.dailyPick;
      case 'VALUE':
        return IdeaSource.value;
      case 'GROWTH':
        return IdeaSource.growth;
      default:
        return IdeaSource.aiConviction;
    }
  }

  /// Apply a small personalization boost (max +6) so ideas that match the
  /// user's onboarding interests rank higher — WITHOUT altering the engine
  /// score shown to the user.
  static _Ranked _personalize(TradeIdea idea, UserPrefs prefs) {
    double boost = 0;
    if (prefs.hasInterest) {
      switch (idea.source) {
        case IdeaSource.momentum:
          if (prefs.likes(Interest.momentum) || prefs.likes(Interest.swing)) {
            boost += 6;
          }
          break;
        case IdeaSource.value:
          if (prefs.likes(Interest.value) || prefs.likes(Interest.dividend)) {
            boost += 6;
          }
          break;
        case IdeaSource.growth:
          if (prefs.likes(Interest.growth)) boost += 6;
          break;
        case IdeaSource.multibagger:
          if (prefs.likes(Interest.multibagger) ||
              prefs.likes(Interest.growth)) {
            boost += 6;
          }
          break;
        case IdeaSource.turnaround:
          if (prefs.likes(Interest.value)) boost += 3;
          break;
        case IdeaSource.aiConviction:
        case IdeaSource.dailyPick:
          boost += 1;
          break;
      }
      // Market match: ideas in a selected market get a small nudge.
      if (prefs.markets.isNotEmpty && prefs.markets.contains(idea.market)) {
        boost += 3;
      }
    }
    return _Ranked(idea, idea.score + boost);
  }
}

class _Ranked {
  const _Ranked(this.idea, this.rank);
  final TradeIdea idea;
  final double rank;
}
