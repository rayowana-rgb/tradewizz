import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/journal_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/repository_scope.dart';

// Regression: the Trade Journal page (pushed bare from Account) must render at
// a real device size (360x800) WITHOUT any RenderFlex overflow (the yellow/black
// stripe). The previous bugs were: the journal entry header row and the shared
// "AI Portfolio Manager" title row overflowed under the TradeWizz themed font.
void main() {
  testWidgets('Journal page has no overflow at device size', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3.0;
    addTearDown(t.view.reset);

    final fake = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/journal/stats')) {
        return http.Response(
            jsonEncode({
              'total_trades': 3,
              'win_rate': 66.0,
              'open_positions': 1,
              'average_gain': 12.5,
              'average_loss': -4.2,
              'best_trade': {'symbol': 'BBCA', 'market': 'IDX'},
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (p.endsWith('/journal')) {
        return http.Response(
            jsonEncode({
              'entries': [
                {
                  'symbol': 'BREN',
                  'market': 'IDX',
                  'score': 88,
                  'signal': 'STRONG BUY',
                  'radar_rank': 2,
                  'portfolio_health': 72,
                  'status': 'OPEN',
                  'realized_return': 1234.5,
                },
              ]
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (p.endsWith('/portfolio/manager')) {
        return http.Response('{"detail":"x"}', 503,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('not found', 404);
    });
    final repo = StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.app/v1'),
        httpClient: fake,
      ),
    );
    final auth = AuthStore()
      ..setSession('JWT',
          const UserProfile(id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));

    await t.pumpWidget(RepositoryScope(
      repository: repo,
      child: AuthScope(
        store: auth,
        child: MaterialApp(home: JournalPage(repository: repo)),
      ),
    ));
    await t.pumpAndSettle();

    // The page renders its own Scaffold + AppBar (it is pushed bare from
    // Account), and the long symbol / STRONG BUY status / wide return must not
    // overflow the row.
    expect(find.text('Trade Journal'), findsOneWidget);
    expect(find.byKey(const Key('journal_entry_BREN')), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
