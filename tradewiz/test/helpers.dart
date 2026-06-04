import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/services/watchlist_scope.dart';
import 'package:tradewiz/services/watchlist_store.dart';

/// Wraps [child] in a MaterialApp + RepositoryScope + WatchlistScope for widget
/// tests. The repository defaults to an offline (mock-fallback) one so pushed
/// routes that read the repository from scope stay hermetic.
Widget wrapApp(
  Widget child, {
  WatchlistStore? store,
  bool seed = false,
  StockRepository? repository,
}) {
  return RepositoryScope(
    repository: repository ?? offlineRepository(),
    child: WatchlistScope(
      store: store ?? WatchlistStore(seed: seed),
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
}

/// A repository whose HTTP layer is always "offline", so it exercises the
/// mock-fallback path. Keeps widget tests hermetic (no real network).
StockRepository offlineRepository() {
  final offline = MockClient((_) async => throw http.ClientException('offline'));
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(
        baseUrl: 'https://test.tradewiz.app/v1',
        mockFallback: true,
      ),
      httpClient: offline,
    ),
  );
}
