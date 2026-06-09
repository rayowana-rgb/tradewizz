import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/home/todays_ideas.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/phase3.dart';
import 'package:tradewiz/models/subscription.dart';
import 'package:tradewiz/models/user_profile_prefs.dart';

DailyPicks _picks() => DailyPicks(title: 't', date: 'd', picks: [
      const DailyPick(
        rank: 1,
        symbol: 'BBCA',
        market: Market.idx,
        name: 'Bank Central Asia',
        score: 88,
        signal: 'BUY',
        recommendation: 'Strong accumulation.',
      ),
    ]);

OpportunitiesResult _radar() => const OpportunitiesResult(
      globalTop10: [
        Opportunity(
          symbol: 'NVDA',
          market: Market.us,
          name: 'NVIDIA',
          score: 91,
          signal: 'BUY',
          recommendation: 'BUY',
          opportunityReason: 'Momentum breakout.',
          marketRegime: 'BULL',
        ),
        // Duplicate of BBCA from a lower-scoring engine: should be de-duped.
        Opportunity(
          symbol: 'BBCA',
          market: Market.idx,
          name: 'Bank Central Asia',
          score: 70,
          signal: 'HOLD',
          recommendation: '',
          opportunityReason: 'Lower score.',
          marketRegime: 'NEUTRAL',
        ),
      ],
      usTop10: [],
      idxTop10: [],
      multibaggerCandidates: [],
    );

MultibaggerResult _multi() => const MultibaggerResult(criteria: [], candidates: [
      MultibaggerCandidate(
        symbol: 'GOTO',
        market: Market.idx,
        name: 'GoTo',
        score: 80,
        conviction: 'HIGH',
        riskLevel: 'HIGH',
        reason: 'High upside.',
      ),
    ]);

AutoWatchlistSuggestions _auto() => const AutoWatchlistSuggestions(suggestions: [
      AutoWatchlistSuggestion(
        symbol: 'TLKM',
        market: Market.idx,
        name: 'Telkom',
        score: 78,
        signal: 'WATCH',
        origin: 'VALUE',
        reason: 'Undervalued.',
      ),
    ]);

void main() {
  test('merges four engines into one ranked, source-labelled feed', () {
    final ideas = TodaysIdeas.fromEngines(
      dailyPicks: _picks(),
      radar: _radar(),
      autoWatchlist: _auto(),
      multibagger: _multi(),
    );
    final symbols = ideas.ideas.map((i) => i.symbol).toList();
    expect(symbols, contains('NVDA'));
    expect(symbols, contains('BBCA'));
    expect(symbols, contains('GOTO'));
    expect(symbols, contains('TLKM'));
    // Ranked by score desc -> NVDA (91) first.
    expect(ideas.ideas.first.symbol, 'NVDA');
  });

  test('de-duplicates a symbol across engines, keeping the best', () {
    final ideas = TodaysIdeas.fromEngines(
      dailyPicks: _picks(), // BBCA 88 BUY
      radar: _radar(), // also BBCA 70 HOLD
    );
    final bbca = ideas.ideas.where((i) => i.symbol == 'BBCA').toList();
    expect(bbca.length, 1); // de-duped
    expect(bbca.first.score, 88); // kept the higher-scoring representation
    expect(bbca.first.source, IdeaSource.dailyPick);
  });

  test('labels sources without exposing the engine', () {
    final ideas = TodaysIdeas.fromEngines(radar: _radar(), multibagger: _multi());
    final nvda = ideas.ideas.firstWhere((i) => i.symbol == 'NVDA');
    final goto = ideas.ideas.firstWhere((i) => i.symbol == 'GOTO');
    expect(nvda.source, IdeaSource.momentum); // BUY -> Momentum
    expect(goto.source, IdeaSource.multibagger);
  });

  test('personalization boosts matching interests without changing the score',
      () {
    // Without interest, NVDA (91, momentum) ranks above GOTO (80, multibagger).
    final neutral = TodaysIdeas.fromEngines(radar: _radar(), multibagger: _multi());
    expect(neutral.ideas.first.symbol, 'NVDA');

    // A multibagger-loving IDX user: GOTO gets +6 (multibagger) +3 (market) =
    // 89, still below NVDA 91. Confirm displayed score is untouched.
    final prefs = const UserPrefs(
      markets: [Market.idx],
      interests: [Interest.multibagger],
    );
    final personalized = TodaysIdeas.fromEngines(
      radar: _radar(),
      multibagger: _multi(),
      prefs: prefs,
    );
    final goto = personalized.ideas.firstWhere((i) => i.symbol == 'GOTO');
    expect(goto.score, 80); // displayed score unchanged by personalization
  });

  test('empty feed when no engines provide data', () {
    expect(TodaysIdeas.fromEngines().isEmpty, isTrue);
    expect(const TodaysIdeas.empty().isEmpty, isTrue);
  });
}
