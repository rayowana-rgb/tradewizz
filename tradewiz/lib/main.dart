import 'package:flutter/material.dart';

import 'models/market.dart';
import 'pages/ai_analysis_page.dart';
import 'pages/dashboard_page.dart';
import 'pages/screener_page.dart';
import 'pages/watchlist_page.dart';
import 'services/watchlist_scope.dart';
import 'services/watchlist_store.dart';
import 'theme.dart';
import 'widgets/market_selector.dart';

void main() {
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

  @override
  void initState() {
    super.initState();
    _watchlist.load();
  }

  @override
  void dispose() {
    _watchlist.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WatchlistScope(
      store: _watchlist,
      child: MaterialApp(
        title: 'TradeWiz',
        debugShowCheckedModeBanner: false,
        theme: buildTradeWizTheme(),
        home: const HomeShell(),
      ),
    );
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
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(market: _market),
      ScreenerPage(market: _market),
      WatchlistPage(market: _market),
      AiAnalysisPage(market: _market),
    ];

    final titles = ['Dashboard', 'Screener', 'Watchlist', 'AI Analysis'];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          titles[_index],
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 22),
        ),
        actions: [
          if (_index != 1 && _index != 3)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: MarketSelector(
                selected: _market,
                onChanged: _onMarketChanged,
              ),
            ),
        ],
      ),
      body: SafeArea(child: pages[_index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.radar_outlined),
            selectedIcon: Icon(Icons.radar),
            label: 'Screener',
          ),
          NavigationDestination(
            icon: Icon(Icons.star_outline),
            selectedIcon: Icon(Icons.star),
            label: 'Watchlist',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'AI Analysis',
          ),
        ],
      ),
    );
  }
}
