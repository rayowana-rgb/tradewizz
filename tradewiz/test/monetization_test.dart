import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/subscription.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/account_page.dart';
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

const _allEliteFeatures = [
  'global_markets',
  'opportunity_radar',
  'daily_top_opportunities',
  'multibagger_finder',
  'portfolio_health',
  'position_quality',
];

Map<String, dynamic> _entitlementsBody(String tier, {bool preview = false}) {
  final unlimited = preview || tier != 'FREE';
  // In preview mode the backend unlocks ALL features regardless of tier and
  // returns the preview_features to badge.
  final features = preview
      ? _allEliteFeatures
      : tier == 'ELITE'
          ? _allEliteFeatures
          : tier == 'PRO'
              ? ['global_markets', 'opportunity_radar',
                  'daily_top_opportunities']
              : ['global_markets'];
  return {
    'user_id': 1,
    'tier': tier,
    'active': true,
    'expires_at': null,
    'preview': preview,
    'preview_features': preview
        ? _allEliteFeatures.where((f) => f != 'global_markets').toList()
        : <String>[],
    'limits': {
      'watchlist_max': unlimited ? -1 : 20,
      'analysis_per_day': unlimited ? -1 : 5,
      'screener_max_results': unlimited ? -1 : 20,
    },
    'features': features,
    'usage': {
      'analysis_count': 0,
      'analysis_limit': unlimited ? -1 : 5,
      'analysis_remaining': unlimited ? -1 : 5,
    },
  };
}

/// Repository whose subscription/radar/health endpoints return canned data.
/// `tierRef` lets a test flip the active tier (e.g. after an upgrade POST).
StockRepository _monRepo({
  required List<String> tierRef,
  bool preview = false,
  List<String>? waitlistJoins,
}) {
  final fake = MockClient((req) async {
    final path = req.url.path;
    Map<String, dynamic>? body;
    if (path.endsWith('/subscription/plans')) {
      body = {..._plansBody(), 'preview': preview};
    } else if (path.endsWith('/subscription/entitlements')) {
      body = _entitlementsBody(tierRef.first, preview: preview);
    } else if (path.endsWith('/subscription/upgrade')) {
      final decoded = jsonDecode(req.body) as Map<String, dynamic>;
      tierRef[0] = (decoded['tier'] as String).toUpperCase();
      body = _entitlementsBody(tierRef.first, preview: preview);
    } else if (path.endsWith('/subscription/waitlist')) {
      final decoded = jsonDecode(req.body) as Map<String, dynamic>;
      final tier = (decoded['tier'] as String).toUpperCase();
      waitlistJoins?.add(tier);
      body = {
        'user_id': 1,
        'tier': tier,
        'status': 'waitlisted',
        'preview': true,
        'message': 'TradeWizz $tier is currently in preview. You have been '
            'added to the early-access waiting list.',
      };
    } else if (path.endsWith('/subscription/event')) {
      body = {'user_id': 1, 'recorded': true};
    } else if (path.endsWith('/sim/portfolio')) {
      body = {
        'account': {
          'cash': 1000000.0,
          'equity': 1000000.0,
          'buying_power': 1000000.0,
          'market_value': 0.0,
          'unrealized_pnl': 0.0,
          'realized_pnl': 0.0,
          'currency': 'USD',
          'simulated': true,
          'disclaimer': 'Simulated. No real broker order is sent.',
        },
        'positions': [],
        'simulated': true,
        'disclaimer': 'Simulated. No real broker order is sent.',
      };
    } else if (path.endsWith('/sim/trades')) {
      body = {'trades': [], 'simulated': true};
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
  // --- Preview early-access screen (no prices, waiting list) ----------------
  testWidgets('Upgrade page shows preview banner + comparison (no prices)',
      (tester) async {
    final repo = _monRepo(tierRef: ['FREE'], preview: true);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(
        _wrap(UpgradePage(repository: repo), repo, entitlements: ent));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('current_plan_card')), findsOneWidget);
    expect(find.byKey(const Key('preview_banner')), findsOneWidget);
    // Join Waiting List CTAs replace Upgrade buttons; no prices anywhere.
    expect(find.byKey(const Key('waitlist_button_PRO')), findsOneWidget);
    expect(find.byKey(const Key('waitlist_button_ELITE')), findsOneWidget);
    expect(find.text('Join Waiting List'), findsWidgets);
    expect(find.textContaining(r'$9.99'), findsNothing);
    expect(find.textContaining(r'$29.99'), findsNothing);
    expect(find.textContaining('/mo'), findsNothing);
    // The comparison table is lower in the list; scroll it into view.
    await tester.scrollUntilVisible(
      find.byKey(const Key('comparison_table')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('comparison_table')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('upgrade_disclaimer')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('upgrade_disclaimer')), findsOneWidget);
  });

  testWidgets('Join Waiting List records intent + shows preview dialog',
      (tester) async {
    final joins = <String>[];
    final repo = _monRepo(
        tierRef: ['FREE'], preview: true, waitlistJoins: joins);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(
        _wrap(UpgradePage(repository: repo), repo, entitlements: ent));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('waitlist_button_PRO')));
    await tester.pumpAndSettle();

    // The waiting-list join was recorded; the tier is NOT changed (no payment).
    expect(joins, contains('PRO'));
    expect(ent.tier, Tier.free);
    // The early-access dialog is shown with the exact preview copy.
    expect(find.byKey(const Key('waitlist_dialog')), findsOneWidget);
    expect(
        find.textContaining('early-access waiting list'), findsOneWidget);
  });

  // --- Feature locking (LockedFeature) -------------------------------------
  testWidgets('LockedFeature shows PREVIEW badge but keeps content open',
      (tester) async {
    final repo = _monRepo(tierRef: ['FREE'], preview: true);
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
    // Content stays visible (no blur/lock) and a PRO PREVIEW badge is shown.
    expect(find.text('secret content'), findsOneWidget);
    expect(find.byKey(const Key('preview_badge_PRO')), findsOneWidget);
    expect(find.byKey(const Key('upgrade_cta_PRO')), findsNothing);
  });

  testWidgets('LockedFeature blurs + upgrade CTA when preview is OFF',
      (tester) async {
    final repo = _monRepo(tierRef: ['FREE']); // preview off
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
    // Dormant paywall re-armed: the locked upgrade CTA appears.
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

  // --- Dashboard PRO Preview cards ------------------------------------------
  testWidgets('Dashboard shows the PRO Preview header + four cards',
      (tester) async {
    final repo = _monRepo(tierRef: ['FREE'], preview: true);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(_wrap(
      SingleChildScrollView(child: PremiumDashboardSection(repository: repo)),
      repo,
      entitlements: ent,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pro_preview_header')), findsOneWidget);
    expect(find.byKey(const Key('dash_card_opportunities')), findsOneWidget);
    expect(find.byKey(const Key('dash_card_daily')), findsOneWidget);
    expect(find.byKey(const Key('dash_card_multibagger')), findsOneWidget);
    expect(find.byKey(const Key('dash_card_health')), findsOneWidget);
    // The product descriptions are present.
    expect(
        find.text(
            'Find the strongest opportunities across global markets.'),
        findsOneWidget);
    expect(find.text('Discover potential future market leaders.'),
        findsOneWidget);
  });

  testWidgets('FREE preview dashboard is open with PREVIEW badges (no CTAs)',
      (tester) async {
    final repo = _monRepo(tierRef: ['FREE'], preview: true);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(_wrap(
      SingleChildScrollView(child: PremiumDashboardSection(repository: repo)),
      repo,
      entitlements: ent,
    ));
    await tester.pumpAndSettle();
    // Everything is open: no hard-paywall upgrade CTAs.
    expect(find.byKey(const Key('upgrade_cta_PRO')), findsNothing);
    expect(find.byKey(const Key('upgrade_cta_ELITE')), findsNothing);
    // PRO PREVIEW / ELITE PREVIEW badges are shown on the cards.
    expect(find.text('PRO PREVIEW'), findsWidgets);
    expect(find.text('ELITE PREVIEW'), findsWidgets);
    // Live data was loaded for the FREE user (portfolio-health score shown).
    expect(find.textContaining('84'), findsWidgets);
  });

  testWidgets('ELITE user (preview off) sees live dashboard content',
      (tester) async {
    final repo = _monRepo(tierRef: ['ELITE']); // preview off
    final ent = _entStore(repo, 'ELITE');
    await ent.refresh('JWT');
    await tester.pumpWidget(_wrap(
      SingleChildScrollView(child: PremiumDashboardSection(repository: repo)),
      repo,
      entitlements: ent,
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('upgrade_cta_PRO')), findsNothing);
    expect(find.byKey(const Key('upgrade_cta_ELITE')), findsNothing);
    expect(find.textContaining('84'), findsWidgets);
  });

  // --- Tier chip ------------------------------------------------------------
  testWidgets('TierChip shows Preview for a FREE preview user', (tester) async {
    final repo = _monRepo(tierRef: ['FREE'], preview: true);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(
        _wrap(const TierChip(), repo, entitlements: ent));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tier_chip')), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
  });

  testWidgets('TierChip reflects the active tier when preview off',
      (tester) async {
    final repo = _monRepo(tierRef: ['PRO']); // preview off
    final ent = _entStore(repo, 'PRO');
    await ent.refresh('JWT');
    await tester.pumpWidget(
        _wrap(const TierChip(), repo, entitlements: ent));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tier_chip')), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
  });

  // --- Account: Early Access Program ----------------------------------------
  testWidgets('Account shows Early Access Program with Preview status',
      (tester) async {
    final repo = _monRepo(tierRef: ['FREE'], preview: true);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(
        _wrap(AccountPage(repository: repo), repo, entitlements: ent));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account_early_access_card')), findsOneWidget);
    expect(find.text('Early Access Program'), findsOneWidget);
    expect(find.byKey(const Key('early_access_status')), findsOneWidget);
    expect(find.text('Preview User'), findsOneWidget);
    expect(find.byKey(const Key('join_pro_waitlist')), findsOneWidget);
    expect(find.byKey(const Key('join_elite_waitlist')), findsOneWidget);
  });

  testWidgets('Account Join ELITE Waiting List records intent + dialog',
      (tester) async {
    final joins = <String>[];
    final repo = _monRepo(
        tierRef: ['FREE'], preview: true, waitlistJoins: joins);
    final ent = _entStore(repo, 'FREE');
    await ent.refresh('JWT');
    await tester.pumpWidget(
        _wrap(AccountPage(repository: repo), repo, entitlements: ent));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('join_elite_waitlist')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('join_elite_waitlist')));
    await tester.pumpAndSettle();

    expect(joins, contains('ELITE'));
    expect(find.byKey(const Key('waitlist_dialog')), findsOneWidget);
    expect(find.textContaining('early-access waiting list'), findsOneWidget);
  });
}
