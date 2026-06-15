import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/pages/news_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/widgets/news_button.dart';

const _feed = {
  'scope': 'GLOBAL',
  'generated_at': '2026-06-15T01:00:00Z',
  'cached': false,
  'fallback': false,
  'items': [
    {
      'id': 'a1',
      'title': 'Global stocks rally as inflation cools',
      'summary': 'Markets jumped...',
      'publisher': 'Reuters',
      'url': 'https://example.com/a1',
      'published_at': '2026-06-15T00:30:00Z',
      'related_symbols': ['^GSPC', '^IXIC'],
    },
    {
      'id': 'a2',
      'title': 'Oil slips on demand worries',
      'publisher': 'Bloomberg',
      'url': 'https://example.com/a2',
      'published_at': '2026-06-14T22:00:00Z',
      'related_symbols': ['CL=F'],
    },
  ],
};

StockRepository _repo({int status = 200}) {
  final fake = MockClient((req) async {
    if (req.url.path.contains('/news')) {
      return http.Response(
        status == 200 ? jsonEncode(_feed) : '{"detail":"down"}',
        status,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 200,
        headers: {'content-type': 'application/json'});
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
      httpClient: fake,
    ),
  );
}

Widget _wrap(Widget child, StockRepository repo) => RepositoryScope(
      repository: repo,
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('News page lists headlines newest-first', (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(NewsPage(repository: repo), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('news_list')), findsOneWidget);
    expect(find.byKey(const Key('news_item_a1')), findsOneWidget);
    expect(find.byKey(const Key('news_item_a2')), findsOneWidget);
    expect(find.text('Global stocks rally as inflation cools'), findsOneWidget);
    expect(find.textContaining('Reuters'), findsOneWidget);
    expect(find.byKey(const Key('news_error')), findsNothing);
  });

  testWidgets('News page shows error state on failure', (tester) async {
    final repo = _repo(status: 503);
    await tester.pumpWidget(_wrap(NewsPage(repository: repo), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('news_error')), findsOneWidget);
    expect(find.byKey(const Key('news_list')), findsNothing);
  });

  testWidgets('News button opens the news page', (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(
      Scaffold(
        appBar: AppBar(actions: [NewsButton(repository: repo)]),
      ),
      repo,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('news_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('news_button')));
    await tester.pumpAndSettle();
    expect(find.text('World Market News'), findsOneWidget);
    expect(find.byKey(const Key('news_list')), findsOneWidget);
  });
}
