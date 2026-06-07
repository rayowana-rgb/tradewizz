import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/broker_connection.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/broker_connections_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/repository_scope.dart';

/// In-memory fake of the /v1/brokers endpoints.
class _FakeBrokers {
  final List<Map<String, dynamic>> conns = [];
  int _next = 1;

  http.Response handle(http.Request req) {
    final p = req.url.path;
    if (req.method == 'GET' && p.endsWith('/brokers')) {
      return _json({'connections': conns});
    }
    if (req.method == 'POST' && p.endsWith('/brokers/connect')) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final type = body['broker_type'] as String;
      final c = {
        'id': _next++,
        'user_id': 1,
        'broker_type': type,
        'display_name': type == 'IBKR' ? 'Interactive Brokers' : 'Moomoo',
        'is_active': true,
        'created_at': '2026-06-07T00:00:00Z',
      };
      conns.add(c);
      return _json(c);
    }
    if (req.method == 'DELETE' && p.contains('/brokers/')) {
      final id = int.parse(p.split('/').last);
      conns.removeWhere((c) => c['id'] == id);
      return _json({'id': id, 'disconnected': true});
    }
    return http.Response('not found', 404);
  }

  http.Response _json(Object body, [int code = 200]) => http.Response(
        jsonEncode(body),
        code,
        headers: {'content-type': 'application/json'},
      );
}

StockRepository _repo(_FakeBrokers broker) => StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
        httpClient: MockClient((req) async => broker.handle(req)),
      ),
    );

Widget _wrap(Widget child, StockRepository repo) {
  final auth = AuthStore();
  auth.setSession('TOKEN', const UserProfile(
    id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
  return RepositoryScope(
    repository: repo,
    child: AuthScope(
      store: auth,
      child: MaterialApp(home: child),
    ),
  );
}

void main() {
  testWidgets('lists Moomoo and IBKR; IBKR shown but unavailable',
      (tester) async {
    final broker = _FakeBrokers();
    final repo = _repo(broker);
    await tester.pumpWidget(_wrap(BrokerConnectionsPage(repository: repo), repo));
    await tester.pumpAndSettle();

    expect(find.text('Moomoo'), findsOneWidget);
    expect(find.text('Interactive Brokers'), findsOneWidget);
    // IBKR is now implemented -> its Connect button is enabled.
    final ibkrConnect = tester.widget<FilledButton>(
        find.byKey(const Key('connect_IBKR')));
    expect(ibkrConnect.onPressed, isNotNull);
    expect(find.text('Coming soon'), findsNothing);
  });

  testWidgets('connect IBKR flow', (tester) async {
    final broker = _FakeBrokers();
    final repo = _repo(broker);
    await tester.pumpWidget(_wrap(BrokerConnectionsPage(repository: repo), repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect_IBKR')));
    await tester.pumpAndSettle();
    expect(broker.conns.any((c) => c['broker_type'] == 'IBKR'), isTrue);
    expect(find.byKey(const Key('disconnect_IBKR')), findsOneWidget);
  });

  testWidgets('connect Moomoo then disconnect', (tester) async {
    final broker = _FakeBrokers();
    final repo = _repo(broker);
    await tester.pumpWidget(_wrap(BrokerConnectionsPage(repository: repo), repo));
    await tester.pumpAndSettle();

    // Connect Moomoo.
    await tester.tap(find.byKey(const Key('connect_MOOMOO')));
    await tester.pumpAndSettle();
    expect(broker.conns.length, 1);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byKey(const Key('disconnect_MOOMOO')), findsOneWidget);

    // Disconnect.
    await tester.tap(find.byKey(const Key('disconnect_MOOMOO')));
    await tester.pumpAndSettle();
    expect(broker.conns, isEmpty);
    expect(find.byKey(const Key('connect_MOOMOO')), findsOneWidget);
  });

  test('BrokerType availability + wire mapping', () {
    expect(BrokerType.moomoo.isAvailable, isTrue);
    expect(BrokerType.ibkr.isAvailable, isTrue);
    expect(BrokerType.moomoo.wire, 'MOOMOO');
    expect(BrokerType.ibkr.wire, 'IBKR');
    expect(BrokerTypeX.fromWire('IBKR'), BrokerType.ibkr);
    expect(BrokerTypeX.fromWire('MOOMOO'), BrokerType.moomoo);
  });
}
