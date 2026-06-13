import '../models/analysis_result.dart';
import '../models/broker.dart';
import '../models/broker_connection.dart';
import '../models/market.dart';
import '../models/market_index.dart';
import '../models/market_overview.dart';
import '../models/phase2.dart';
import '../models/phase3.dart';
import '../models/portfolio.dart';
import '../models/screener_result.dart';
import '../models/simulation.dart';
import '../models/subscription.dart';
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

  // ---------------------------------------------------------------------------
  // Raw-JSON passthroughs used by the client-side cache layer (lib/cache).
  //
  // These return the unparsed response map so the cache can persist a plain
  // JSON-encodable payload (Hive-friendly) and re-parse it with the model's
  // fromJson on read. They are additive and do not change the typed methods
  // above — the live data path / API formats are untouched.
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> rawMarketIndices() =>
      _client.authGet('/market/indices');

  Future<Map<String, dynamic>> rawMorningBrief(String token, Market market) =>
      _client.authGet('/morning-brief/${market.code}', bearer: token);

  Future<Map<String, dynamic>> rawGlobalRotation(String token) =>
      _client.authGet('/rotation/global', bearer: token);

  Future<Map<String, dynamic>> rawRadarOpportunities(String token) =>
      _client.authGet('/radar/opportunities', bearer: token);

  Future<Map<String, dynamic>> rawRadarDaily(String token) =>
      _client.authGet('/radar/daily', bearer: token);

  Future<Map<String, dynamic>> rawRadarMultibagger(String token) =>
      _client.authGet('/radar/multibagger', bearer: token);

  Future<Map<String, dynamic>> rawPortfolioManager(String token) =>
      _client.authGet('/portfolio/manager', bearer: token);

  Future<Map<String, dynamic>> rawRebalance(String token, {String? profile}) {
    var path = '/portfolio/rebalance';
    if (profile != null && profile.isNotEmpty) {
      path = '$path?profile=${Uri.encodeQueryComponent(profile)}';
    }
    return _client.authGet(path, bearer: token);
  }

  Future<Map<String, dynamic>> rawPortfolioHealth(String token) =>
      _client.authGet('/portfolio/health', bearer: token);

  Future<Map<String, dynamic>> rawNotifications(String token) =>
      _client.authGet('/notifications', bearer: token);

  Future<Map<String, dynamic>> rawAutoWatchlistSuggestions(
    String token, {
    List<String> existing = const [],
  }) {
    var path = '/auto-watchlist/suggestions';
    if (existing.isNotEmpty) {
      final qs = existing
          .map((e) => 'existing=${Uri.encodeQueryComponent(e)}')
          .join('&');
      path = '$path?$qs';
    }
    return _client.authGet(path, bearer: token);
  }

  // --- Snapshot endpoints (Phase 6, offline-first) -------------------------
  // One request per surface, served from the backend's pre-computed cache.
  Future<Map<String, dynamic>> rawDashboardSnapshot(
    String token, {
    required Market market,
    bool force = false,
  }) {
    final f = force ? '&force=true' : '';
    return _client.authGet(
      '/snapshot/dashboard?market=${market.code}$f',
      bearer: token,
    );
  }

  Future<Map<String, dynamic>> rawPortfolioSnapshot(
    String token, {
    bool force = false,
  }) {
    final q = force ? '?force=true' : '';
    return _client.authGet('/snapshot/portfolio$q', bearer: token);
  }

  Future<Map<String, dynamic>> rawWatchlistSnapshot(
    String token, {
    required Market market,
    List<String> existing = const [],
    bool force = false,
  }) {
    final params = <String>['market=${market.code}'];
    if (force) params.add('force=true');
    for (final e in existing) {
      params.add('existing=${Uri.encodeQueryComponent(e)}');
    }
    return _client.authGet('/snapshot/watchlist?${params.join('&')}',
        bearer: token);
  }

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

  /// Index quote for a single market (filtered from /market/indices).
  Future<MarketIndex?> marketIndex(Market market) async {
    final list = await marketIndices();
    for (final q in list) {
      if (q.market == market.code) return q;
    }
    return null;
  }

  /// Rule-based Fear/Greed condition for one market. Backs
  /// `/v1/market/condition` (Phase E). Returns [MarketCondition.unknown] on a
  /// data-source failure rather than throwing, so Home degrades gracefully.
  Future<MarketCondition> marketCondition(Market market) async {
    try {
      final j =
          await _client.authGet('/market/condition?market=${market.code}');
      return MarketCondition.fromJson(j);
    } catch (_) {
      return MarketCondition.unknown;
    }
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
  /// Market is required so the backend builds the correct Yahoo ticker.
  Future<Sourced<WeeklyPrediction>> predictWeekly(
    String symbol,
    Market market,
  ) async {
    final res = await _client.predictWeekly(symbol, market);
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

  // --- Simulated paper-trading portfolio (/v1/sim/*) ------------------------
  // Broker-free. Buy/Sell are simulated only; no real order is ever placed.

  /// Simulated account snapshot. Backs `GET /v1/sim/account`.
  Future<SimAccount> simAccount(String token) async {
    final j = await _client.authGet('/sim/account', bearer: token);
    return SimAccount.fromJson(j);
  }

  /// Simulated portfolio (account + positions). Backs `GET /v1/sim/portfolio`.
  Future<SimPortfolio> simPortfolio(String token) async {
    final j = await _client.authGet('/sim/portfolio', bearer: token);
    return SimPortfolio.fromJson(j);
  }

  /// Simulated open positions. Backs `GET /v1/sim/positions`.
  Future<List<SimPosition>> simPositions(String token) async {
    final j = await _client.authGet('/sim/positions', bearer: token);
    return (j['positions'] as List<dynamic>? ?? [])
        .map((e) => SimPosition.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Simulated trade history. Backs `GET /v1/sim/trades`.
  Future<List<SimTrade>> simTrades(String token) async {
    final j = await _client.authGet('/sim/trades', bearer: token);
    return (j['trades'] as List<dynamic>? ?? [])
        .map((e) => SimTrade.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Preview a SIMULATED order (no broker). Backs `POST /v1/sim/order/preview`.
  Future<SimOrderPreview> simPreviewOrder({
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
    final j = await _client.authPost('/sim/order/preview', body, bearer: token);
    return SimOrderPreview.fromJson(j);
  }

  /// Place a SIMULATED order (no broker). Backs `POST /v1/sim/order/place`.
  Future<SimOrderResult> simPlaceOrder({
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
    final j = await _client.authPost('/sim/order/place', body, bearer: token);
    return SimOrderResult.fromJson(j);
  }

  /// Reset the simulated portfolio. Backs `POST /v1/sim/reset`.
  Future<SimAccount> simReset(String token) async {
    await _client.authPost('/sim/reset', const {}, bearer: token);
    return simAccount(token);
  }

  // --- Subscription / monetization -----------------------------------------

  /// Public plan comparison table (FREE / PRO / ELITE) for the paywall.
  Future<PlanComparison> subscriptionPlans() async {
    final j = await _client.authGet('/subscription/plans');
    return PlanComparison.fromJson(j);
  }

  /// Current tier + limits + today's usage; the app gates its UI from this.
  Future<Entitlements> entitlements(String token) async {
    final j = await _client.authGet('/subscription/entitlements', bearer: token);
    return Entitlements.fromJson(j);
  }

  /// Activate a tier (placeholder billing — no real payment is taken).
  Future<Entitlements> upgrade(String token, Tier tier) async {
    await _client.authPost(
      '/subscription/upgrade',
      {'tier': tier.code},
      bearer: token,
    );
    return entitlements(token);
  }

  /// Join the early-access waiting list for a preview tier. No payment is
  /// taken (no Stripe, no app-store billing) — this only records demand.
  Future<Map<String, dynamic>> joinWaitlist(String token, Tier tier) async {
    return _client.authPost(
      '/subscription/waitlist',
      {'tier': tier.code},
      bearer: token,
    );
  }

  /// Record a preview-feature usage event for demand analytics (no enforcement).
  Future<void> recordPreviewEvent(
    String token,
    String event, {
    String meta = '',
  }) async {
    try {
      await _client.authPost(
        '/subscription/event',
        {'event': event, 'meta': meta},
        bearer: token,
      );
    } catch (_) {
      // Analytics are best-effort; never block the UI on a tracking failure.
    }
  }

  // --- AI Opportunity Radar (Pro) ------------------------------------------

  Future<OpportunitiesResult> radarOpportunities(String token) async {
    final j = await _client.authGet('/radar/opportunities', bearer: token);
    return OpportunitiesResult.fromJson(j);
  }

  Future<DailyPicks> radarDaily(String token) async {
    final j = await _client.authGet('/radar/daily', bearer: token);
    return DailyPicks.fromJson(j);
  }

  // --- Multibagger Finder (Elite) ------------------------------------------

  Future<MultibaggerResult> radarMultibagger(String token) async {
    final j = await _client.authGet('/radar/multibagger', bearer: token);
    return MultibaggerResult.fromJson(j);
  }

  // --- Portfolio Health + Position Quality (Elite) -------------------------

  Future<PortfolioHealth> portfolioHealth(String token) async {
    final j = await _client.authGet('/portfolio/health', bearer: token);
    return PortfolioHealth.fromJson(j);
  }

  // --- Phase 2: AI Morning Brief -------------------------------------------

  /// Once-per-session AI Morning Brief for a market. Backs
  /// `GET /v1/morning-brief/{market}`.
  Future<MorningBrief> morningBrief(String token, Market market) async {
    final j = await _client.authGet(
      '/morning-brief/${market.code}',
      bearer: token,
    );
    return MorningBrief.fromJson(j);
  }

  // --- Phase 2: AI Portfolio Manager ---------------------------------------

  /// Rule-based advisory over the simulated portfolio. Backs
  /// `GET /v1/portfolio/manager`.
  Future<PortfolioManagerReport> portfolioManager(String token) async {
    final j = await _client.authGet('/portfolio/manager', bearer: token);
    return PortfolioManagerReport.fromJson(j);
  }

  // --- Phase 2: Portfolio Journal ------------------------------------------

  /// The user's research journal entries. Backs `GET /v1/journal`.
  Future<List<JournalEntry>> journal(String token) async {
    final j = await _client.authGet('/journal', bearer: token);
    return (j['entries'] as List<dynamic>? ?? [])
        .map((e) => JournalEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Aggregate journal statistics. Backs `GET /v1/journal/stats`.
  Future<JournalStats> journalStats(String token) async {
    final j = await _client.authGet('/journal/stats', bearer: token);
    return JournalStats.fromJson(j);
  }

  // --- Phase 2: In-app Notifications ---------------------------------------

  /// List in-app notifications + unread count. Backs `GET /v1/notifications`.
  Future<NotificationList> notifications(String token) async {
    final j = await _client.authGet('/notifications', bearer: token);
    return NotificationList.fromJson(j);
  }

  /// Mark notifications read (specific ids, or all when null). Backs
  /// `POST /v1/notifications/read`.
  Future<int> markNotificationsRead(
    String token, {
    List<int>? ids,
  }) async {
    final j = await _client.authPost(
      '/notifications/read',
      {'ids': ids},
      bearer: token,
    );
    return (j['unread_count'] ?? 0 as num).toInt();
  }

  // --- Phase 3: Auto Watchlist AI ------------------------------------------

  /// Ranked daily watchlist suggestions. Backs
  /// `GET /v1/auto-watchlist/suggestions`. [existing] are the client's current
  /// watchlist keys ("MARKET:SYMBOL" or bare "SYMBOL") to exclude duplicates.
  Future<AutoWatchlistSuggestions> autoWatchlistSuggestions(
    String token, {
    List<String> existing = const [],
  }) async {
    var path = '/auto-watchlist/suggestions';
    if (existing.isNotEmpty) {
      final qs = existing
          .map((e) => 'existing=${Uri.encodeQueryComponent(e)}')
          .join('&');
      path = '$path?$qs';
    }
    final j = await _client.authGet(path, bearer: token);
    return AutoWatchlistSuggestions.fromJson(j);
  }

  /// Apply selected suggestions (or all of today's when [items] is empty).
  /// Backs `POST /v1/auto-watchlist/apply`. [existing] are the client's
  /// current watchlist keys so already-present names are skipped.
  Future<ApplyResult> applyAutoWatchlist(
    String token, {
    List<AutoWatchlistSuggestion> items = const [],
    List<String> existing = const [],
  }) async {
    final body = <String, dynamic>{
      'items': items
          .map((s) => {'symbol': s.symbol, 'market': s.market.code})
          .toList(),
      'existing': existing,
    };
    final j = await _client.authPost(
      '/auto-watchlist/apply',
      body,
      bearer: token,
    );
    return ApplyResult.fromJson(j);
  }

  /// Read Auto Watchlist AI settings. Backs `GET /v1/auto-watchlist/settings`.
  Future<AutoWatchlistSettings> autoWatchlistSettings(String token) async {
    final j = await _client.authGet('/auto-watchlist/settings', bearer: token);
    return AutoWatchlistSettings.fromJson(j);
  }

  /// Persist Auto Watchlist AI settings. Backs
  /// `POST /v1/auto-watchlist/settings`.
  Future<AutoWatchlistSettings> saveAutoWatchlistSettings(
    String token,
    AutoWatchlistSettings settings,
  ) async {
    final j = await _client.authPost(
      '/auto-watchlist/settings',
      settings.toJson(),
      bearer: token,
    );
    return AutoWatchlistSettings.fromJson(j);
  }

  // --- Phase 3: Portfolio Rebalancing AI -----------------------------------

  /// ADD/HOLD/REDUCE/EXIT suggestions over the simulation. Backs
  /// `GET /v1/portfolio/rebalance`.
  Future<RebalanceReport> rebalance(String token, {String? profile}) async {
    var path = '/portfolio/rebalance';
    if (profile != null && profile.isNotEmpty) {
      path = '$path?profile=${Uri.encodeQueryComponent(profile)}';
    }
    final j = await _client.authGet(path, bearer: token);
    return RebalanceReport.fromJson(j);
  }

  // --- Phase 3: Global Rotation Engine -------------------------------------

  /// Rank all markets by opportunity environment. Backs
  /// `GET /v1/rotation/global`.
  Future<GlobalRotation> globalRotation(String token) async {
    final j = await _client.authGet('/rotation/global', bearer: token);
    return GlobalRotation.fromJson(j);
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
