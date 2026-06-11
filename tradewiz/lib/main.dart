import 'package:flutter/material.dart';

import 'cache/cache_service.dart';
import 'cache/cached_repository.dart';
import 'cdn/cdn_repository.dart';
import 'cdn/manifest_service.dart';
import 'home/activation_metrics.dart';
import 'home/activation_scope.dart';
import 'models/market.dart';
import 'pages/account_page.dart';
import 'pages/ai_analysis_page.dart';
import 'pages/home_page.dart';
import 'pages/onboarding_page.dart';
import 'pages/screener_page.dart';
import 'pages/watchlist_page.dart';
import 'repositories/stock_repository.dart';
import 'snapshot/snapshot_repository.dart';
import 'services/auth_scope.dart';
import 'services/auth_store.dart';
import 'services/entitlements_scope.dart';
import 'services/repository_scope.dart';
import 'services/user_prefs_scope.dart';
import 'services/user_prefs_store.dart';
import 'services/watchlist_scope.dart';
import 'services/watchlist_store.dart';
import 'theme_tradewizz.dart';
import 'widgets/ds/ds.dart';
import 'widgets/market_selector.dart';
import 'widgets/notification_bell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Open the local cache (Hive). Falls back to in-memory if it can't open, so
  // the app always boots.
  await CacheService.init();
  runApp(const TradeWizApp());
}

class TradeWizApp extends StatefulWidget {
  const TradeWizApp({super.key});

  @override
  State<TradeWizApp> createState() => _TradeWizAppState();
}

class _TradeWizAppState extends State<TradeWizApp> {
  final WatchlistStore _watchlist =
      WatchlistStore(persistence: SharedPrefsWatchlistPersistence());
  final AuthStore _auth =
      AuthStore(persistence: SharedPrefsAuthPersistence());
  final StockRepository _repository = StockRepository();
  late final EntitlementsStore _entitlements =
      EntitlementsStore(repository: _repository);
  // Phase A: personalization profile (local + best-effort backend sync).
  late final UserPrefsStore _prefs = UserPrefsStore(
    persistence: SharedPrefsUserPrefsPersistence(),
  );
  // Phase I: activation/retention funnel instrumentation.
  late final ActivationMetrics _metrics = ActivationMetrics(
    sink: (event, {meta = ''}) async {
      final token = _auth.token;
      if (token != null) {
        await _repository.recordPreviewEvent(token, event, meta: meta);
      }
    },
  );

  void _syncEntitlements() => _entitlements.syncToken(_auth.token);

  @override
  void initState() {
    super.initState();
    _watchlist.load();
    _prefs.load();
    // Reload entitlements whenever the session token changes (login/logout).
    _auth.addListener(_syncEntitlements);
    _auth.load();
  }

  @override
  void dispose() {
    _auth.removeListener(_syncEntitlements);
    _watchlist.dispose();
    _auth.dispose();
    _entitlements.dispose();
    _prefs.dispose();
    _metrics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepositoryScope(
      repository: _repository,
      // Use the shared, persistent (Hive-backed) cache in production so SWR
      // state survives navigation and relaunches.
      cached: CachedRepository(_repository, cache: CacheService.instance),
      // Offline-first snapshot repository on the shared persistent cache.
      snapshot:
          SnapshotRepository(_repository, cache: CacheService.instance),
      // Global Snapshot CDN (Phase 7): manifest-driven, delta downloads, served
      // to all users from the edge. Uses the shared Hive cache.
      cdn: CdnRepository(ManifestService(), cache: CacheService.instance),
      child: AuthScope(
        store: _auth,
        child: EntitlementsScope(
          store: _entitlements,
          child: WatchlistScope(
            store: _watchlist,
            child: UserPrefsScope(
              store: _prefs,
              child: ActivationScope(
                metrics: _metrics,
                child: MaterialApp(
                  title: 'TradeWizz',
                  debugShowCheckedModeBanner: false,
                  // Dark "Wizard Terminal" theme app-wide so every surface
                  // (onboarding, loading, login, main shell) is consistent.
                  // No light surface should ever flash through.
                  theme: buildTradeWizzTheme(),
                  darkTheme: buildTradeWizzTheme(),
                  themeMode: ThemeMode.dark,
                  home: const RootGate(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Decides between onboarding (first launch) and the main shell (Phase A/H).
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = UserPrefsScope.of(context);
    if (!prefs.isLoaded) {
      return const Scaffold(
        backgroundColor: TWColors.bgBase,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!prefs.onboarded) {
      return OnboardingPage(
        // Completing onboarding updates prefs.onboarded, which rebuilds this
        // gate via UserPrefsScope and swaps to the main shell.
        onDone: () {},
      );
    }
    return const HomeShell();
  }
}

/// Top-level shell holding the shared market selection and bottom navigation.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  Market _market = Market.idx;

  void _onMarketChanged(Market market) {
    setState(() => _market = market);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Lead with the user's primary onboarding market the first time.
    final prefs = UserPrefsScope.maybeOf(context)?.prefs;
    if (prefs != null && prefs.markets.isNotEmpty) {
      _market = prefs.primaryMarket;
    }
  }

  // Final navigation — Home / Watchlist / Explore / AI Analysis / Account.
  // (Portfolio moved into Account, which is now the portfolio hub.)
  @override
  Widget build(BuildContext context) {
    final pages = [
      // Phase 12: Home adopts the dark "Wizard Terminal" design language via a
      // scoped Theme override, so the redesign ships as a self-contained
      // vertical slice without changing the other tabs' Material theme.
      Theme(
        data: buildTradeWizzTheme(),
        child: HomePage(market: _market),
      ),
      Theme(
        data: buildTradeWizzTheme(),
        child: WatchlistPage(market: _market),
      ),
      Theme(
        data: buildTradeWizzTheme(),
        child: ScreenerPage(market: _market),
      ),
      Theme(
        data: buildTradeWizzTheme(),
        child: AiAnalysisPage(market: _market),
      ),
      Theme(
        data: buildTradeWizzTheme(),
        child: const AccountPage(),
      ),
    ];

    const titles = ['Home', 'Watchlist', 'Explore', 'AI Analysis', 'Account'];
    // Market selector only on market-scoped tabs (Home, Watchlist, Explore).
    const marketScoped = {0, 1, 2};

    // Wrap the whole shell (AppBar with the notification bell + scaffold
    // background + bottom nav) in the dark "Wizard Terminal" theme so no light
    // Material surfaces show through at the top or bottom edges.
    return Theme(
      data: buildTradeWizzTheme(),
      child: Scaffold(
      backgroundColor: TWColors.bgBase,
      appBar: AppBar(
        backgroundColor: TWColors.bgBase,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          titles[_index],
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
        ),
        actions: [
          if (marketScoped.contains(_index))
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: MarketSelector(
                selected: _market,
                onChanged: _onMarketChanged,
              ),
            ),
          const NotificationBell(),
          const SizedBox(width: 4),
        ],
      ),
      // Let page content extend behind the translucent nav bar so it shows
      // faintly through the glass (more vertical room for content).
      extendBody: true,
      // IndexedStack keeps every tab mounted, so Explore's filter state (and
      // loaded results / scroll position) survive Home <-> Explore switches.
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _index, children: pages),
      ),
      bottomNavigationBar: TWGlassNavBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.star_outline),
            selectedIcon: Icon(Icons.star),
            label: 'Watchlist',
          ),
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: 'Explore',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'AI Analysis',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Account',
          ),
        ],
      ),
      ),
    );
  }
}

