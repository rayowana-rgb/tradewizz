import '../models/analysis_result.dart';
import '../models/broker.dart';
import '../models/broker_connection.dart';
import '../models/market.dart';
import '../models/market_index.dart';
import '../models/market_overview.dart';
import '../models/portfolio.dart';
import '../models/screener_result.dart';
import '../models/user.dart';
import '../services/api_client.dart';
import '../services/data_source.dart';

/// High-level access point for stock data.
///
/// The UI talks to the repository; the repository talks to [ApiClient]. Results
/// are wrapped in [Sourced] so the UI can show whether data is live or fallback.
/// Hard failures throw [ApiException]; callers map that to an error/offline
/// status in the UI.
class StockRepository {
  StockRepository({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// Full analysis for a single symbol. Backs `/analyze/{symbol}`.
  Future<Sourced<AnalysisResult>> analyze(String symbol, Market market) async {
    final res = await _client.analyze(symbol, market);
    return Sourced(AnalysisResult.fromJson(res.data), res.source);
  }

  /// Screener results for a market. Backs `/screen/{market}`.
  ///
  /// Optional [limit] (top-N), [minScore], and [categories] (wire names) are
  /// forwarded to the API as query params when set.
  Future<Sourced<ScreenerResult>> screen(
    Market market, {
    int? limit,
    double? minScore,
    List<String>? categories,
  }) async {
    final res = await _client.screen(
      market,
      limit: limit,
      minScore: minScore,
      categories: categories,
    );
    return Sourced(ScreenerResult.fromJson(res.data), res.source);
  }

  /// Latest index quotes for all markets. Backs `/v1/market/indices`.
  ///
  /// Never falls back to mock data: a failure throws [ApiException] so the
  /// Dashboard can show "Index data unavailable" instead of wrong values.
  Future<List<MarketIndex>> marketIndices() async {
    final j = await _client.authGet('/market/indices');
    return parseMarketIndices(j);
  }

  /// Dashboard Market Overview. Backs `/v1/market/overview/{market}`.
  ///
  /// Never falls back to mock data: a failure throws [ApiException] so the
  /// Dashboard can show an "overview unavailable" state.
  Future<MarketOverview> marketOverview(Market market) async {
    final j = await _client.authGet('/market/overview/${market.code}');
    return MarketOverview.fromJson(j);
  }

  /// Weekly prediction for a symbol. Backs `/predict_weekly/{symbol}`.
  Future<Sourced<WeeklyPrediction>> predictWeekly(String symbol) async {
    final res = await _client.predictWeekly(symbol);
    return Sourced(WeeklyPrediction.fromJson(res.data), res.source);
  }

  /// Backtest a buy-signal rule for a symbol. Backs `/backtest/{symbol}`.
  Future<Sourced<BacktestResult>> backtest(
    String symbol,
    Market market, {
    String signalType = 'momentum',
    int forwardDays = 2,
  }) async {
    final res = await _client.backtest(
      symbol,
      market,
      signalType: signalType,
      forwardDays: forwardDays,
    );
    return Sourced(BacktestResult.fromJson(res.data), res.source);
  }

  // --- Broker (Moomoo) manual trading ---------------------------------------

  /// Broker connection + trading-env status. Backs `/v1/broker/status`.
  Future<BrokerStatus> brokerStatus() async {
    final j = await _client.brokerGet('/broker/status');
    return BrokerStatus.fromJson(j);
  }

  /// Preview an IBKR order (validates, does NOT place). Authenticated; backs
  /// `POST /v1/brokers/ibkr/order/preview`. Orders go to the user's connected
  /// IBKR (paper) account, not the legacy single-broker Moomoo endpoint.
  Future<OrderPreview> previewOrder({
    required String token,
    required String symbol,
    required Market market,
    required OrderSide side,
    required double quantity,
    required OrderTypeKind orderType,
    double? price,
  }) async {
    final body = <String, dynamic>{
      'symbol': symbol,
      'market': market.code,
      'side': side.wire,
      'quantity': quantity,
      'order_type': orderType.wire,
    };
    if (price != null) body['price'] = price;
    final j = await _client.authPost(
      '/brokers/ibkr/order/preview',
      body,
      bearer: token,
    );
    return OrderPreview.fromJson(j);
  }

  /// Place an IBKR order — requires the confirmation token from a preview.
  /// Authenticated; backs `POST /v1/brokers/ibkr/order/place`. The backend
  /// surfaces clear errors (Read-Only mode, insufficient funds, rejected).
  Future<OrderResult> placeOrder({
    required String token,
    required String symbol,
    required Market market,
    required OrderSide side,
    required double quantity,
    required OrderTypeKind orderType,
    double? price,
    required String confirmationToken,
  }) async {
    final body = <String, dynamic>{
      'symbol': symbol,
      'market': market.code,
      'side': side.wire,
      'quantity': quantity,
      'order_type': orderType.wire,
      'confirmation_token': confirmationToken,
    };
    if (price != null) body['price'] = price;
    final j = await _client.authPost(
      '/brokers/ibkr/order/place',
      body,
      bearer: token,
    );
    return OrderResult.fromJson(j);
  }

  // --- Auth -----------------------------------------------------------------

  /// Register a new account. Backs `/v1/auth/register`.
  Future<AuthResult> register(String email, String password) async {
    final j = await _client.authPost(
      '/auth/register',
      {'email': email, 'password': password},
    );
    return AuthResult.fromJson(j);
  }

  /// Log in. Backs `/v1/auth/login`.
  Future<AuthResult> login(String email, String password) async {
    final j = await _client.authPost(
      '/auth/login',
      {'email': email, 'password': password},
    );
    return AuthResult.fromJson(j);
  }

  /// Sign in / register with a Google ID token. Backs `/v1/auth/google`.
  /// Only the resulting TradeWizz session is kept by the caller; the Google
  /// token is not stored.
  Future<AuthResult> googleLogin(String idToken) async {
    final j = await _client.authPost('/auth/google', {'id_token': idToken});
    return AuthResult.fromJson(j);
  }

  /// Sign in / register with an Apple identity token. Backs `/v1/auth/apple`.
  Future<AuthResult> appleLogin(String idToken) async {
    final j = await _client.authPost('/auth/apple', {'id_token': idToken});
    return AuthResult.fromJson(j);
  }

  /// Current user profile for a token. Backs `/v1/auth/me`.
  Future<UserProfile> me(String token) async {
    final j = await _client.authGet('/auth/me', bearer: token);
    return UserProfile.fromJson(j);
  }

  /// Log out (server is stateless; this just notifies). `/v1/auth/logout`.
  Future<void> logout(String token) async {
    await _client.authPost('/auth/logout', const {}, bearer: token);
  }

  // --- Broker connections ---------------------------------------------------

  /// List the user's broker connections. Backs `GET /v1/brokers`.
  Future<List<BrokerConnection>> brokerConnections(String token) async {
    final j = await _client.authGet('/brokers', bearer: token);
    final list = (j['connections'] as List<dynamic>? ?? []);
    return list
        .map((e) => BrokerConnection.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Connect a broker. Backs `POST /v1/brokers/connect`.
  Future<BrokerConnection> connectBroker(
    String token,
    BrokerType type, {
    String? displayName,
  }) async {
    final body = <String, dynamic>{'broker_type': type.wire};
    if (displayName != null) body['display_name'] = displayName;
    final j = await _client.authPost('/brokers/connect', body, bearer: token);
    return BrokerConnection.fromJson(j);
  }

  /// Disconnect a broker by id. Backs `DELETE /v1/brokers/{id}`.
  Future<void> disconnectBroker(String token, int id) async {
    await _client.authDelete('/brokers/$id', bearer: token);
  }

  // --- Unified portfolio ----------------------------------------------------

  /// Aggregated portfolio across the user's connected brokers.
  /// Backs `GET /v1/portfolio`.
  Future<UnifiedPortfolio> portfolio(String token) async {
    final j = await _client.authGet('/portfolio', bearer: token);
    return UnifiedPortfolio.fromJson(j);
  }

  /// Portfolio performance analytics. Backs `GET /v1/portfolio/performance`.
  Future<PortfolioPerformance> portfolioPerformance(String token) async {
    final j = await _client.authGet('/portfolio/performance', bearer: token);
    return PortfolioPerformance.fromJson(j);
  }

  /// Capture a portfolio snapshot. Backs `POST /v1/portfolio/snapshot`.
  Future<void> capturePortfolioSnapshot(String token) async {
    await _client.authPost('/portfolio/snapshot', const {}, bearer: token);
  }
}
