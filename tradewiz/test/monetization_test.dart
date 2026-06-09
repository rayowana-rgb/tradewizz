import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/subscription.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/upgrade_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/entitlements_scope.dart';
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/widgets/premium.dart';
import 'package:tradewiz/widgets/premium_dashboard.dart';

// --- Backend fixtures -------------------------------------------------------

Map<String, dynamic> _plansBody() => {
      'tiers': [
        {
          'tier': 'FREE',
          'price_usd_month': 0.0,
          'description': 'Free starter.',
          'limits': {
            'watchlist_max': 20,
            'analysis_per_day': 5,
            'screener_max_results': 20,
          },
          'features': ['global_markets'],
        },
        {
          'tier': 'PRO',
          'price_usd_month': 9.99,
          'description': 'Unlimited research.',
          'limits': {
            'watchlist_max': -1,
            'analysis_per_day': -1,
            'screener_max_results': -1,
          },
          'features': [
            'global_markets',
            'opportunity_radar',
            'daily_top_opportunities',
          ],
        },
        {
          'tier': 'ELITE',
          'price_usd_month': 29.99,
          'description': 'Everything.',
          'limits': {
            'watchlist_max': -1,
            'analysis_per_day': -1,
            'screener_max_results': -1,
          },
          'features': [
            'global_markets',
            'opportunity_radar',
            'daily_top_opportunities',
            'multibagger_finder',
            'portfolio_health',
          ],
        },
      ],
      'features': [
        {
          'key': 'opportunity_radar',
          'label': 'AI Opportunity Radar',
          'min_tier': 'PRO',
          'tiers': {'FREE': false, 'PRO': true, 'ELITE': true},
        },
        {
          'key': 'portfolio_health',
          'label': 'Portfolio Health Score',
          'min_tier': 'ELITE',
          'tiers': {'FREE': false, 'PRO': false, 'ELITE': true},
        },
      ],
    };

Map<String, dynamic> _entitlementsBody(String tier) {
  final unlimited = tier != 'FREE';
  return {
    'user_id': 1,
    'tier': tier,
    'active': true,
    'expires_at': null,
    'limits': {
      'watchlist_max': unlimited ? -1 : 20,
      'analysis_per_day': unlimited ? -1 : 5,
      'screener_max_results': unlimited ? -1 : 20,
    },
    'features': tier == 'ELITE'
        ? ['global_markets', 'opportunity_radar', 'daily_top_opportunities',
            'multibagger_finder', 'portfolio_health']
        : tier == 'PRO'
            ? ['global_markets', 'opportunity_radar', 'daily_top_opportunities']
            : ['global_markets'],
    'usage': {
      'analysis_count': 0,
      'analysis_limit': unlimited ? -1 : 5,
      'analysis_remaining': unlimited ? -1 : 5,
    },
  };
}

/// Repository whose subscription/radar/health endpoints return canned data.
/// `tierRef` lets a test flip the active tier (e.g. after an upgrade POST).
StockRepository _monRepo({required List<String> tierRef}) {
  final fake = MockClient((req) async {
    final path = req.url.path;
    Map<String, dynamic>? body;
    if (path.endsWith('/subscription/plans')) {
      body = _plansBody();
    } else if (path.endsWith('/subscription/entitlements')) {
      body = _entitlementsBody(tierRef.first);
    } else if (path.endsWith('/subscription/upgrade')) {
      final decoded = jsonDecode(req.body) as Map<String, dynamic>;
      tierRef[0] = (decoded['tier'] as String).toUpperCase();
      body = _entitlementsBody(tierRef.first);
    } else if (path.endsWith('/radar/opportunities')) {
      body = {
        'generated_at': 't',
        'global_top10': [
          {'symbol': 'NVDA', 'market': 'US', 'score': 93, 'signal': 'BUY',
           'recommendation': 'Strong Buy', 'opportunity_reason': 'r',
           'market_regime': 'BULL'},
        ],
        'us_top10': [],
        'idx_top10': [],
        'multibagger_candidates': [],
      };
    } else if (path.endsWith('/radar/daily')) {
      body = {
        'title': "Today's Top Opportunities",
        'generated_at': 't',
        'date': '2026-06-09',
        'picks': [
          {'rank': 1, 'symbol': 'NVDA', 'market': 'US', 'score': 93,
           'signal': 'BUY', 'recommendation': 'Buy'},
        ],
      };
    } else if (path.endsWith('/radar/multibagger')) {
      body = {
        'generated_at': 't',
        'criteria': ['Bull market regime'],
        'candidates': [
          {'symbol': 'MPMX', 'market': 'IDX', 'score': 92,
           'conviction': 'HIGH', 'risk_level': 'MEDIUM', 'reason': 'r'},
        ],
      };
    } else if (path.endsWith('/portfolio/health')) {
      body = {
        'user_id': 1,
        'generated_at': 't',
        'health_score': 84,
        'rating': 'Good',
        'components': {
          'diversification': 70, 'concentration_risk': 80,
          'liquidity': 75, 'quality': 82, 'sector_exposure': 60,
        },
        'warnings': ['Position concentration too high in technology'],
        'strengths': ['BBCA remains strong'],
        'exit_warnings': [],
        'market_exposure': {'US': 100.0},
        'positions': [],
        'simulated': true,
      };
    }
    if (body != null) {
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('not found', 404);
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
      httpClient: fake,
    ),
  );
}

AuthStore _loggedIn() {
  final s = AuthStore();
  s.setSession('JWT',
      const UserProfile(id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
  return s;
}

/// Wrap a widget with Repository + Auth + Entitlements scopes. The entitlements
/// store is seeded for [tier] so gating renders deterministically.
Widget _wrap(
  Widget child,
  StockRepository repo, {
  required EntitlementsStore entitlements,
}) {
  return RepositoryScope(
    repository: repo,
    child: AuthScope(
      store: _loggedIn(),
      child: EntitlementsScope(
        store: entitlements,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    ),
  );
}

EntitlementsStore _entStore(StockRepository repo, String tier) {
  final s = EntitlementsStore(repository: repo);
  // Seed the tier synchronously by loading entitlements for the test token.
  return s;
}

void main() {
  // --- Upgrade / paywall screen --------------------------------------------
  testWidgets('Upgrade page shows current plan + comparison table',
      (tester) async {
    final repo = _monRepo(tierRef: ['FREE']);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(
        _wrap(UpgradePage(repository: repo), repo, entitlements: ent));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('current_plan_card')), findsOneWidget);
    expect(find.byKey(const Key('current_plan_label')), findsOneWidget);
    expect(find.text('Free'), findsWidgets);
    // Upgrade CTAs for PRO + ELITE are shown for a FREE user.
    expect(find.byKey(const Key('upgrade_button_PRO')), findsOneWidget);
    expect(find.byKey(const Key('upgrade_button_ELITE')), findsOneWidget);
    // The comparison table is lower in the list; scroll it into view.
    await tester.scrollUntilVisible(
      find.byKey(const Key('comparison_table')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('comparison_table')), findsOneWidget);
    expect(find.byKey(const Key('upgrade_disclaimer')), findsOneWidget);
  });

  testWidgets('Upgrade flow upgrades FREE -> PRO', (tester) async {
    final tierRef = ['FREE'];
    final repo = _monRepo(tierRef: tierRef);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(
        _wrap(UpgradePage(repository: repo), repo, entitlements: ent));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('upgrade_button_PRO')));
    await tester.pumpAndSettle();

    // Backend now reports PRO and the entitlements store reflects it.
    expect(tierRef.first, 'PRO');
    expect(ent.tier, Tier.pro);
  });

  // --- Feature locking (LockedFeature) -------------------------------------
  testWidgets('LockedFeature blurs + shows upgrade CTA for FREE',
      (tester) async {
    final repo = _monRepo(tierRef: ['FREE']);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(_wrap(
      const SizedBox(
        height: 120,
        child: LockedFeature(
          requiredTier: Tier.pro,
          feature: 'opportunity_radar',
          title: 'Top Opportunities',
          child: Text('secret content'),
        ),
      ),
      repo,
      entitlements: ent,
    ));
    await tester.pumpAndSettle();
    // The upgrade CTA is present (locked).
    expect(find.byKey(const Key('upgrade_cta_PRO')), findsOneWidget);
  });

  testWidgets('LockedFeature renders child for entitled tier', (tester) async {
    final repo = _monRepo(tierRef: ['PRO']);
    final ent = _entStore(repo, 'PRO');
    await ent.refresh('JWT');
    await tester.pumpWidget(_wrap(
      const SizedBox(
        height: 120,
        child: LockedFeature(
          requiredTier: Tier.pro,
          feature: 'opportunity_radar',
          child: Text('secret content'),
        ),
      ),
      repo,
      entitlements: ent,
    ));
    await tester.pumpAndSettle();
    expect(find.text('secret content'), findsOneWidget);
    expect(find.byKey(const Key('upgrade_cta_PRO')), findsNothing);
  });

  // --- Dashboard premium cards ---------------------------------------------
  testWidgets('Dashboard shows all four premium cards', (tester) async {
    final repo = _monRepo(tierRef: ['FREE']);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(_wrap(
      SingleChildScrollView(child: PremiumDashboardSection(repository: repo)),
      repo,
      entitlements: ent,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dash_card_opportunities')), findsOneWidget);
    expect(find.byKey(const Key('dash_card_daily')), findsOneWidget);
    expect(find.byKey(const Key('dash_card_multibagger')), findsOneWidget);
    expect(find.byKey(const Key('dash_card_health')), findsOneWidget);
  });

  testWidgets('FREE dashboard cards are locked with upgrade CTAs',
      (tester) async {
    final repo = _monRepo(tierRef: ['FREE']);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(_wrap(
      SingleChildScrollView(child: PremiumDashboardSection(repository: repo)),
      repo,
      entitlements: ent,
    ));
    await tester.pumpAndSettle();
    // Both PRO and ELITE upgrade CTAs appear (locked previews).
    expect(find.byKey(const Key('upgrade_cta_PRO')), findsWidgets);
    expect(find.byKey(const Key('upgrade_cta_ELITE')), findsWidgets);
  });

  testWidgets('ELITE user sees live dashboard content (no CTAs)',
      (tester) async {
    final repo = _monRepo(tierRef: ['ELITE']);
    final ent = _entStore(repo, 'ELITE');
    await ent.refresh('JWT');
    await tester.pumpWidget(_wrap(
      SingleChildScrollView(child: PremiumDashboardSection(repository: repo)),
      repo,
      entitlements: ent,
    ));
    await tester.pumpAndSettle();
    // Live data loaded; no locked upgrade CTAs remain.
    expect(find.byKey(const Key('upgrade_cta_PRO')), findsNothing);
    expect(find.byKey(const Key('upgrade_cta_ELITE')), findsNothing);
    // The portfolio-health card shows the live score.
    expect(find.textContaining('84'), findsWidgets);
  });

  // --- Tier chip ------------------------------------------------------------
  testWidgets('TierChip reflects the active tier', (tester) async {
    final repo = _monRepo(tierRef: ['PRO']);
    final ent = _entStore(repo, 'PRO');
    await ent.refresh('JWT');
    await tester.pumpWidget(
        _wrap(const TierChip(), repo, entitlements: ent));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tier_chip')), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
  });
}
