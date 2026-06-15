import 'package:flutter/material.dart';

import '../models/broker.dart';
import '../models/market.dart';
import '../models/screener_category.dart';
import '../models/screener_result.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/data_source.dart';
import '../services/repository_scope.dart';
import '../state/explore_filter_store.dart';
import '../theme_tradewizz.dart';
import '../widgets/category_badge.dart';
import '../widgets/connection_pill.dart';
import '../widgets/broker_open_sheet.dart';
import '../widgets/ds/ds.dart';
import 'ai_analysis_page.dart';
import 'order_ticket_page.dart';

/// Non-order action emitted by the swipe-left menu (alongside [OrderSide]).
enum _ScreenerAction { broker }

/// Screener page: runs `/screen/{market}` and lists tagged matches with
/// market + category filters. iOS-first UX (pull-to-refresh, clean cards).
class ScreenerPage extends StatefulWidget {
  const ScreenerPage({
    super.key,
    this.market,
    this.repository,
    this.filterStore,
  });

  /// Market preselected from the app shell.
  final Market? market;
  final StockRepository? repository;

  /// In-memory filter persistence. Defaults to the process-wide singleton so
  /// selections survive tab switches; tests can inject a fresh store.
  final ExploreFilterStore? filterStore;

  @override
  State<ScreenerPage> createState() => _ScreenerPageState();
}

class _ScreenerPageState extends State<ScreenerPage> {
  late final StockRepository _repo = widget.repository ?? StockRepository();
  ExploreFilterStore get _store =>
      widget.filterStore ?? ExploreFilterStore.instance;

  late Market _market = widget.market ?? Market.idx;
  ScreenerCategory? _categoryFilter;
  double _minScore = 0;
  final _searchCtrl = TextEditingController();
  String _query = '';
  // Phase 10D extra filters (client-side, visual): signal + liquidity.
  String? _signalFilter; // BUY / HOLD / SELL
  bool _hideIlliquid = false;

  /// Push the current filter selection into the in-memory store so it survives
  /// tab switches / widget rebuilds. View-state only; nothing scoring-related.
  void _persistFilters() {
    _store.save(
      market: _market,
      categoryFilter: _categoryFilter,
      minScore: _minScore,
      signalFilter: _signalFilter,
      hideIlliquid: _hideIlliquid,
      query: _query,
    );
  }

  // Pagination: requested top-N grows by _pageSize up to _maxLimit.
  static const int _pageSize = 50;
  static const int _maxLimit = 200;
  int _limit = _pageSize;
  bool _loadingMore = false;

  bool _loading = false;
  String? _error;
  ScreenerResult? _result;
  DataSource? _source;

  @override
  void initState() {
    super.initState();
    // Restore previously selected filters (Home -> Explore round-trip).
    if (_store.hydrated) {
      _categoryFilter = _store.categoryFilter;
      _minScore = _store.minScore;
      _signalFilter = _store.signalFilter;
      _hideIlliquid = _store.hideIlliquid;
      _query = _store.query;
      _searchCtrl.text = _store.query;
      // The shell still owns the market; only fall back to the stored market
      // when the shell didn't pass one.
      if (widget.market == null && _store.market != null) {
        _market = _store.market!;
      }
    }
    _run();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ScreenerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.market != null && widget.market != _market) {
      _market = widget.market!;
      _run();
    }
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Pass params only when a filter is active (limit always bounds results).
      final result = await _repo.screen(
        _market,
        limit: _limit,
        minScore: _minScore > 0 ? _minScore : null,
        categories: _categoryFilter != null
            ? [_categoryFilter!.wireName]
            : null,
      );
      if (!mounted) return;
      setState(() {
        _result = result.data;
        _source = result.source;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _source = e.statusCode == null ? DataSource.offline : DataSource.error;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not run screener. $e';
        _source = DataSource.error;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectMarket(Market m) {
    if (m == _market) return;
    setState(() {
      _market = m;
      _limit = _pageSize; // reset pagination on context change
    });
    _persistFilters();
    _run();
  }

  void _selectCategory(ScreenerCategory? c) {
    setState(() {
      _categoryFilter = c;
      _limit = _pageSize;
    });
    _persistFilters();
    _run(); // re-query server-side with the category filter
  }

  bool get _canLoadMore =>
      (_result?.hasMore ?? false) && _limit < _maxLimit;

  Future<void> _loadMore() async {
    if (!_canLoadMore || _loadingMore) return;
    setState(() {
      _limit = (_limit + _pageSize).clamp(_pageSize, _maxLimit);
      _loadingMore = true;
    });
    try {
      await _run();
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _openAnalysis(ScreenerMatch match) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnalysisDetailPage(
          symbol: match.symbol,
          market: _market,
          repository: widget.repository,
        ),
      ),
    );
  }

  /// Open the shared simulated order ticket for a screener match. Reuses the
  /// exact same OrderTicketPage as Analysis/Watchlist/Account — simulation only.
  void _openTicket(ScreenerMatch match, OrderSide side) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OrderTicketPage(
          symbol: match.symbol,
          market: _market,
          side: side,
          repository: widget.repository ?? RepositoryScope.of(context),
        ),
      ),
    );
  }

  /// Swipe-left action sheet: Buy / Sell. Never deletes the row.
  Future<void> _showBuySellMenu(ScreenerMatch match) async {
    final choice = await showModalBottomSheet<Object>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              key: const Key('screener_action_menu'),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('${match.symbol} · ${_market.code}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            ListTile(
              key: const Key('screener_action_buy'),
              leading: const Icon(Icons.add_circle_outline,
                  color: TWColors.up),
              title: const Text('Buy (simulated)'),
              onTap: () => Navigator.of(ctx).pop(OrderSide.buy),
            ),
            ListTile(
              key: const Key('screener_action_sell'),
              leading: const Icon(Icons.remove_circle_outline,
                  color: TWColors.down),
              title: const Text('Sell (simulated)'),
              onTap: () => Navigator.of(ctx).pop(OrderSide.sell),
            ),
            const Divider(height: 1, color: TWColors.hairline),
            // Read-only hand-off to the user's real broker app for this symbol.
            ListTile(
              key: const Key('screener_action_open_broker'),
              leading: const Icon(Icons.open_in_new_rounded,
                  color: TWColors.accent),
              title: const Text('Open in broker'),
              subtitle: const Text(
                'View this symbol in your broker app',
                style:
                    TextStyle(color: TWColors.textTertiary, fontSize: 12),
              ),
              onTap: () => Navigator.of(ctx).pop(_ScreenerAction.broker),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                'Simulation mode only. No real broker order will be sent.',
                style: TextStyle(color: TWColors.textTertiary, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice is OrderSide) {
      _openTicket(match, choice);
    } else if (choice == _ScreenerAction.broker) {
      // Smart read-only hand-off: emits broker_open_clicked, then opens the
      // preferred broker (or the picker) on this bare symbol.
      await openBrokerFlow(
        context,
        symbol: match.symbol,
        market: _market,
        source: 'screener',
      );
    }
  }

  /// Open the bulk-buy sheet for every stock currently in the filtered list.
  /// The user picks ONE quantity (applied per stock) and Market or Limit (each
  /// stock limited at its own last price). Simulation only.
  Future<void> _openBulkBuy() async {
    final matches = _filtered;
    if (matches.isEmpty) return;
    final token = AuthScope.read(context).token;
    if (token == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please sign in to use the simulation portfolio.'),
        ),
      );
      return;
    }
    final config = await showModalBottomSheet<_BulkBuyConfig>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BulkBuySheet(
        market: _market,
        count: matches.length,
      ),
    );
    if (!mounted || config == null) return;
    await _runBulkBuy(matches, config, token);
  }

  /// Place a simulated BUY for each match sequentially (no tight loop), then
  /// report a summary: filled / skipped (insufficient cash) / failed.
  Future<void> _runBulkBuy(
    List<ScreenerMatch> matches,
    _BulkBuyConfig config,
    String token,
  ) async {
    final repo = widget.repository ?? RepositoryScope.of(context);
    var filled = 0;
    var skipped = 0;
    var failed = 0;
    final failures = <String>[];

    // Progress dialog so the user knows a multi-order run is in flight.
    final progress = ValueNotifier<int>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BulkProgressDialog(
        total: matches.length,
        progress: progress,
      ),
    );

    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final price = config.orderType == OrderTypeKind.limit ? m.price : null;
      try {
        await repo.simPlaceOrder(
          token: token,
          symbol: m.symbol,
          market: _market,
          side: OrderSide.buy,
          quantity: config.quantity,
          orderType: config.orderType,
          price: price,
        );
        filled++;
      } on ApiException catch (e) {
        // Insufficient cash is an expected, non-fatal outcome: skip & continue.
        if ((e.message).toLowerCase().contains('cash')) {
          skipped++;
        } else {
          failed++;
          failures.add('${m.symbol}: ${e.message}');
        }
      } catch (e) {
        failed++;
        failures.add('${m.symbol}: $e');
      }
      progress.value = i + 1;
    }

    progress.dispose();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close progress dialog

    await showDialog<void>(
      context: context,
      builder: (_) => _BulkResultDialog(
        total: matches.length,
        filled: filled,
        skipped: skipped,
        failed: failed,
        failures: failures,
      ),
    );
  }

  // Server already filters; keep a defensive local pass for fallback data.
  List<ScreenerMatch> get _filtered {
    final matches = _result?.matches ?? [];
    final q = _query.trim().toUpperCase();
    return matches.where((m) {
      if (_minScore > 0 && m.score < _minScore) return false;
      if (_categoryFilter != null && !m.hasCategory(_categoryFilter!)) {
        return false;
      }
      if (_signalFilter != null &&
          m.signal.toUpperCase() != _signalFilter) {
        return false;
      }
      if (_hideIlliquid && m.signal.toUpperCase() == 'AVOID') {
        return false;
      }
      if (q.isNotEmpty &&
          !m.symbol.toUpperCase().contains(q) &&
          !m.name.toUpperCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
  }

  int get _activeFilterCount {
    var n = 0;
    if (_categoryFilter != null) n++;
    if (_minScore > 0) n++;
    if (_signalFilter != null) n++;
    if (_hideIlliquid) n++;
    return n;
  }

  Future<void> _openFilters() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FiltersSheet(
        market: _market,
        category: _categoryFilter,
        minScore: _minScore,
        signal: _signalFilter,
        hideIlliquid: _hideIlliquid,
        onApply: (m, cat, min, sig, hide) {
          setState(() {
            _market = m;
            _categoryFilter = cat;
            _minScore = min;
            _signalFilter = sig;
            _hideIlliquid = hide;
            _limit = _pageSize;
          });
          _persistFilters();
          // Market / category / min-score are server-side params; re-query.
          // Signal + liquidity are applied client-side in _filtered.
          _run();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TWScaffoldBackground(
      child: Column(
      children: [
        // Phase 10D: Search + a single Filters entry point (bottom sheet).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('screener_search'),
                  controller: _searchCtrl,
                  onChanged: (v) {
                    setState(() => _query = v);
                    _persistFilters();
                  },
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search symbol or company…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                              _persistFilters();
                            },
                          ),
                    isDense: true,
                    filled: true,
                    fillColor: TWColors.surfaceCard,
                    hintStyle: TWType.body.copyWith(color: TWColors.textTertiary),
                    prefixIconColor: TWColors.textTertiary,
                    suffixIconColor: TWColors.textTertiary,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: TWSpace.lg, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: TWRadius.rButton,
                      borderSide: const BorderSide(color: TWColors.hairline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: TWRadius.rButton,
                      borderSide: const BorderSide(color: TWColors.hairline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: TWRadius.rButton,
                      borderSide:
                          const BorderSide(color: TWColors.accent, width: 1.4),
                    ),
                  ),
                  style: TWType.body.copyWith(color: TWColors.textPrimary),
                  cursorColor: TWColors.accentBright,
                ),
              ),
              const SizedBox(width: 8),
              _FiltersButton(
                count: _activeFilterCount,
                onTap: _openFilters,
              ),
            ],
          ),
        ),
        // Quick market + category chips remain for fast access.
        _MarketFilterBar(selected: _market, onSelected: _selectMarket),
        _CategoryFilterBar(
          selected: _categoryFilter,
          onSelected: _selectCategory,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Text('Data source', style: TWType.caption),
              const Spacer(),
              ConnectionPill(source: _source),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ConnectionBanner(
            source: _source,
            onRetry: _run,
            retrying: _loading,
          ),
        ),
        if (_result != null) _CacheBanner(result: _result!),
        // Bulk action bar: buy every stock currently in the filtered list with
        // one quantity/order-type. Simulation only — reuses the sim endpoints.
        if (!_loading && _error == null && _filtered.isNotEmpty)
          _BulkActionBar(
            count: _filtered.length,
            onBuyAll: _openBulkBuy,
          ),
        const Divider(height: 1, color: TWColors.hairline),
        Expanded(child: _buildBody()),
      ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const TWBusyIndicator(
        title: 'Screening the market…',
        subtitle:
            'Pulling fresh data and ranking matches. This can take a moment.',
      );
    }
    if (_error != null) {
      return _ScreenerError(message: _error!, onRetry: _run);
    }
    final matches = _filtered;
    if (matches.isEmpty) {
      return _ScreenerEmpty(
        hasFilter: _categoryFilter != null,
        onClearFilter: () {
          setState(() => _categoryFilter = null);
          _persistFilters();
        },
        onRefresh: _run,
      );
    }
    final result = _result;
    return RefreshIndicator(
      onRefresh: _run,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        // +1 for the footer (count + optional Load More).
        itemCount: matches.length + 1,
        separatorBuilder: (_, index) => const SizedBox(height: 12),
        itemBuilder: (_, i) {
          if (i < matches.length) {
            final match = matches[i];
            return Dismissible(
              key: Key('screener_row_${match.symbol}_${_market.code}'),
              direction: DismissDirection.endToStart,
              // Swipe-left reveals a Buy/Sell menu; it never deletes the row.
              confirmDismiss: (_) async {
                await _showBuySellMenu(match);
                return false;
              },
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: TWColors.accent.withValues(alpha: 0.18),
                  borderRadius: TWRadius.rCard,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.swap_horiz, size: 20,
                        color: TWColors.accentBright),
                    const SizedBox(width: 6),
                    Text('Buy / Sell',
                        style: TWType.label
                            .copyWith(color: TWColors.accentBright)),
                  ],
                ),
              ),
              child: _MatchCard(
                match: match,
                onTap: () => _openAnalysis(match),
              ),
            );
          }
          return _ScreenerFooter(
            shown: result?.shownCount ?? matches.length,
            total: result?.totalCount ?? matches.length,
            canLoadMore: _canLoadMore,
            loadingMore: _loadingMore,
            atMax: _limit >= _maxLimit,
            onLoadMore: _loadMore,
          );
        },
      ),
    );
  }
}

/// Market-close cache status banner: shows the "Cached market-close result"
/// label + generated_at, and an open-market notice when the market is open.
/// Hidden when the server reports no cache metadata (older backends).
class _CacheBanner extends StatelessWidget {
  const _CacheBanner({required this.result});

  final ScreenerResult result;

  String _formatGeneratedAt() {
    final dt = result.generatedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    // Only render when the backend actually reported cache metadata.
    final hasMeta = result.cached ||
        result.marketStatus != null ||
        result.nextRefreshRule != null;
    if (!hasMeta) return const SizedBox.shrink();

    final open = result.isMarketOpen;
    final children = <Widget>[
      Row(
        children: [
          Icon(
            result.cached ? Icons.history : Icons.bolt,
            size: 16,
            color: TWColors.accentBright,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              result.cached
                  ? 'Cached market-close result'
                  : 'Fresh market-close result',
              key: const Key('screener_cache_label'),
              style: TWType.label,
            ),
          ),
          Text(
            _formatGeneratedAt(),
            key: const Key('screener_generated_at'),
            style: TWType.tabular(TWType.caption),
          ),
        ],
      ),
    ];

    if (open) {
      children.add(const SizedBox(height: 6));
      children.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 14, color: TWColors.warn),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Screening uses latest saved result to avoid slow loading '
                'during market hours.',
                key: const Key('screener_open_warning'),
                style: TWType.caption.copyWith(color: TWColors.textSecondary),
              ),
            ),
          ],
        ),
      );
    } else if (result.nextRefreshRule != null) {
      children.add(const SizedBox(height: 4));
      children.add(
        Text(
          result.nextRefreshRule!,
          key: const Key('screener_refresh_rule'),
          style: TWType.caption,
        ),
      );
    }

    if (result.warning != null && open) {
      children.add(const SizedBox(height: 4));
      children.add(
        Text(
          result.warning!,
          key: const Key('screener_cache_warning'),
          style: TWType.caption.copyWith(color: TWColors.warn),
        ),
      );
    }

    return Container(
      width: double.infinity,
      color: open
          ? TWColors.warn.withValues(alpha: 0.10)
          : TWColors.accent.withValues(alpha: 0.08),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// "Showing X of Y" count + Load More control at the bottom of the list.
class _ScreenerFooter extends StatelessWidget {
  const _ScreenerFooter({
    required this.shown,
    required this.total,
    required this.canLoadMore,
    required this.loadingMore,
    required this.atMax,
    required this.onLoadMore,
  });

  final int shown;
  final int total;
  final bool canLoadMore;
  final bool loadingMore;
  final bool atMax;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        children: [
          Text(
            'Showing $shown of $total',
            style: TWType.tabular(TWType.caption),
          ),
          const SizedBox(height: 10),
          if (canLoadMore)
            SizedBox(
              width: double.infinity,
              child: loadingMore
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : OutlinedButton.icon(
                      onPressed: onLoadMore,
                      icon: const Icon(Icons.expand_more),
                      label: const Text('Load more'),
                    ),
            )
          else if (atMax && total > shown)
            Text(
              'Showing the top $shown (max).',
              style: TWType.caption,
            ),
        ],
      ),
    );
  }
}

/// Immutable result of the bulk-buy sheet: quantity-per-stock + order type.
class _BulkBuyConfig {
  const _BulkBuyConfig({required this.quantity, required this.orderType});
  final double quantity;
  final OrderTypeKind orderType;
}

/// Slim action bar above the list: "Buy all (N)" — simulation bulk entry point.
class _BulkActionBar extends StatelessWidget {
  const _BulkActionBar({required this.count, required this.onBuyAll});
  final int count;
  final VoidCallback onBuyAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: const Key('screener_buy_all_button'),
          onPressed: onBuyAll,
          style: FilledButton.styleFrom(
            backgroundColor: TWColors.up,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: TWRadius.rButton),
          ),
          icon: const Icon(Icons.shopping_cart_checkout_rounded, size: 18),
          label: Text('Buy all ($count) · simulated'),
        ),
      ),
    );
  }
}

/// Bottom sheet to configure a bulk simulated buy of every filtered match.
class _BulkBuySheet extends StatefulWidget {
  const _BulkBuySheet({required this.market, required this.count});
  final Market market;
  final int count;

  @override
  State<_BulkBuySheet> createState() => _BulkBuySheetState();
}

class _BulkBuySheetState extends State<_BulkBuySheet> {
  final _qtyController = TextEditingController(text: '100');
  final _formKey = GlobalKey<FormState>();
  OrderTypeKind _orderType = OrderTypeKind.market;

  @override
  void dispose() {
    _qtyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.shopping_cart_checkout_rounded,
                      color: TWColors.up),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Buy all ${widget.count} matches',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.market.flag} ${widget.market.code} · simulation only. '
                'The same quantity is bought for every stock in the current '
                'list. Orders with not enough simulated cash are skipped.',
                style: const TextStyle(
                    color: TWColors.textTertiary, fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('bulk_qty_field'),
                controller: _qtyController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Quantity per stock',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final q = double.tryParse(v?.trim() ?? '');
                  if (q == null || q <= 0) return 'Enter a positive quantity';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              const Text('Order type',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    key: const Key('bulk_type_market'),
                    selected: _orderType == OrderTypeKind.market,
                    label: const Text('Market'),
                    onSelected: (_) =>
                        setState(() => _orderType = OrderTypeKind.market),
                  ),
                  ChoiceChip(
                    key: const Key('bulk_type_limit'),
                    selected: _orderType == OrderTypeKind.limit,
                    label: const Text('Limit @ last price'),
                    onSelected: (_) =>
                        setState(() => _orderType = OrderTypeKind.limit),
                  ),
                ],
              ),
              if (_orderType == OrderTypeKind.limit) ...[
                const SizedBox(height: 8),
                const Text(
                  'Each stock is limited at its own last traded price.',
                  style: TextStyle(
                      color: TWColors.textTertiary, fontSize: 12),
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('bulk_confirm_button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: TWColors.up,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () {
                    if (!_formKey.currentState!.validate()) return;
                    Navigator.of(context).pop(
                      _BulkBuyConfig(
                        quantity:
                            double.parse(_qtyController.text.trim()),
                        orderType: _orderType,
                      ),
                    );
                  },
                  child: Text('Buy all ${widget.count} (simulated)'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Modal progress while the bulk run places one order at a time.
class _BulkProgressDialog extends StatelessWidget {
  const _BulkProgressDialog({required this.total, required this.progress});
  final int total;
  final ValueNotifier<int> progress;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: ValueListenableBuilder<int>(
        valueListenable: progress,
        builder: (context, done, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: total == 0 ? null : done / total,
              color: TWColors.up,
            ),
            const SizedBox(height: 16),
            Text('Placing simulated orders…  $done / $total',
                style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// Summary after a bulk run: filled / skipped (insufficient cash) / failed.
class _BulkResultDialog extends StatelessWidget {
  const _BulkResultDialog({
    required this.total,
    required this.filled,
    required this.skipped,
    required this.failed,
    required this.failures,
  });
  final int total;
  final int filled;
  final int skipped;
  final int failed;
  final List<String> failures;

  @override
  Widget build(BuildContext context) {
    Widget line(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(text)),
            ],
          ),
        );
    return AlertDialog(
      key: const Key('bulk_result_dialog'),
      title: const Text('Bulk buy complete'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line(Icons.check_circle, TWColors.up,
              '$filled filled (simulated)'),
          if (skipped > 0)
            line(Icons.account_balance_wallet_outlined, TWColors.warn,
                '$skipped skipped — not enough simulated cash'),
          if (failed > 0)
            line(Icons.error_outline, TWColors.down, '$failed failed'),
          if (failures.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(
                child: Text(
                  failures.take(10).join('\n'),
                  style: const TextStyle(
                      fontSize: 12, color: TWColors.textTertiary),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            'Simulation only. No real broker orders were sent.',
            style: TextStyle(fontSize: 12, color: TWColors.textTertiary),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _MarketFilterBar extends StatelessWidget {
  const _MarketFilterBar({required this.selected, required this.onSelected});
  final Market selected;
  final ValueChanged<Market> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          for (final m in Market.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: m == selected,
                label: Text('${m.flag} ${m.code}'),
                onSelected: (_) => onSelected(m),
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryFilterBar extends StatelessWidget {
  const _CategoryFilterBar({required this.selected, required this.onSelected});
  final ScreenerCategory? selected;
  final ValueChanged<ScreenerCategory?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              selected: selected == null,
              label: const Text('All'),
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final c in ScreenerCategory.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                selected: c == selected,
                avatar: Icon(c.icon, size: 16, color: c.color),
                label: Text(c.label),
                onSelected: (sel) => onSelected(sel ? c : null),
              ),
            ),
        ],
      ),
    );
  }
}

/// Quick min-score selector (chips). 0 means "no minimum".
/// Phase 10D: a single "Filters" entry point that opens the bottom sheet.
class _FiltersButton extends StatelessWidget {
  const _FiltersButton({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      key: const Key('screener_filters_button'),
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: TWColors.textPrimary,
        backgroundColor: TWColors.surfaceCard,
        padding: const EdgeInsets.symmetric(horizontal: TWSpace.lg, vertical: 12),
        side: const BorderSide(color: TWColors.hairline),
        shape: RoundedRectangleBorder(borderRadius: TWRadius.rButton),
      ),
      icon: const Icon(Icons.tune, size: 18),
      label: Text(count == 0 ? 'Filters' : 'Filters ($count)'),
    );
  }
}

/// Phase 10D: the consolidated filter bottom sheet — Market, Category, Min
/// Score, Signal, Liquidity. Purely visual/UX; it drives the SAME state and
/// the SAME server params as before (no scoring/ranking change).
class _FiltersSheet extends StatefulWidget {
  const _FiltersSheet({
    required this.market,
    required this.category,
    required this.minScore,
    required this.signal,
    required this.hideIlliquid,
    required this.onApply,
  });

  final Market market;
  final ScreenerCategory? category;
  final double minScore;
  final String? signal;
  final bool hideIlliquid;
  final void Function(
    Market market,
    ScreenerCategory? category,
    double minScore,
    String? signal,
    bool hideIlliquid,
  ) onApply;

  @override
  State<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends State<_FiltersSheet> {
  late Market _market = widget.market;
  late ScreenerCategory? _category = widget.category;
  late double _minScore = widget.minScore;
  late String? _signal = widget.signal;
  late bool _hideIlliquid = widget.hideIlliquid;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Filters',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
              const SizedBox(height: 12),
              _label('Market'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in Market.values)
                    ChoiceChip(
                      selected: m == _market,
                      label: Text('${m.flag} ${m.code}'),
                      onSelected: (_) => setState(() => _market = m),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _label('Category'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    selected: _category == null,
                    label: const Text('All'),
                    onSelected: (_) => setState(() => _category = null),
                  ),
                  for (final c in ScreenerCategory.values)
                    ChoiceChip(
                      selected: _category == c,
                      label: Text(c.label),
                      onSelected: (_) => setState(() => _category = c),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _label('Min Score'),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in const <double>[0, 50, 70, 90])
                    ChoiceChip(
                      selected: v == _minScore,
                      label: Text(v == 0 ? 'Any' : '≥ ${v.toInt()}'),
                      onSelected: (_) => setState(() => _minScore = v),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _label('Signal'),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    selected: _signal == null,
                    label: const Text('Any'),
                    onSelected: (_) => setState(() => _signal = null),
                  ),
                  for (final s in const ['BUY', 'HOLD', 'SELL'])
                    ChoiceChip(
                      selected: _signal == s,
                      label: Text(s),
                      onSelected: (_) => setState(() => _signal = s),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _label('Liquidity'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _hideIlliquid,
                onChanged: (v) => setState(() => _hideIlliquid = v),
                title: const Text('Hide illiquid / not-investable',
                    style: TextStyle(fontSize: 15)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => setState(() {
                        _market = widget.market;
                        _category = null;
                        _minScore = 0;
                        _signal = null;
                        _hideIlliquid = false;
                      }),
                      child: const Text('Reset'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('screener_filters_apply'),
                      onPressed: () {
                        widget.onApply(_market, _category, _minScore,
                            _signal, _hideIlliquid);
                        Navigator.of(context).pop();
                      },
                      child: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 12)),
      );
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match, this.onTap});
  final ScreenerMatch match;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final changeColor = match.isUp ? TWColors.up : TWColors.down;
    final sign = match.isUp ? '+' : '';
    return TWFloatingCard(
      onTap: onTap,
      padding: const EdgeInsets.all(TWSpace.lg),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(match.symbol, style: TWType.title3),
                      Text(
                        match.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TWType.caption,
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      match.price.toStringAsFixed(match.price >= 100 ? 0 : 2),
                      style: TWType.tabular(TWType.label)
                          .copyWith(color: TWColors.textPrimary),
                    ),
                    Text(
                      '$sign${match.changePercent.toStringAsFixed(2)}%',
                      style: TWType.tabular(TWType.caption)
                          .copyWith(color: changeColor),
                    ),
                  ],
                ),
                const SizedBox(width: TWSpace.md),
                // Phase 9A: the pill shows the FINAL Explore Score (what the
                // list is sorted by), not the Base Score.
                _ScorePill(score: match.effectiveFinalScore),
                // Broker hand-off is offered in the swipe-left action menu
                // (below Buy / Sell), not on the card itself.
              ],
            ),
            // Phase 9A: Explore score breakdown (Final = Base + Bonus +
            // Conviction). Only shown when the server sent the overlay.
            if (match.finalScore != null) ...[
              const SizedBox(height: 10),
              _ScoreBreakdown(match: match),
            ],
            if (match.exploreTags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in match.exploreTags) _ExploreTag(label: t),
                ],
              ),
            ] else if (match.categories.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in match.categories)
                    CategoryBadge(category: c, compact: true),
                ],
              ),
            ],
          ],
        ),
    );
  }
}

/// Phase 10D: the Final Explore Score is TradeWizz's hero metric — render it
/// as the loudest element on the card.
class _ScorePill extends StatelessWidget {
  const _ScorePill({required this.score});
  final double score;

  @override
  Widget build(BuildContext context) {
    final color = TWColors.confidence(score);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.md, vertical: TWSpace.sm),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [TWColors.accentBright, TWColors.accent],
        ),
        borderRadius: TWRadius.rSm,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        score.toStringAsFixed(0),
        style: TWType.tabular(TWType.title2).copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          height: 1.0,
        ),
      ),
    );
  }
}

/// Phase 9A: shows how the Final Explore Score is composed:
/// Final = Base + Category Bonus + Conviction.
class _ScoreBreakdown extends StatelessWidget {
  const _ScoreBreakdown({required this.match});
  final ScreenerMatch match;

  @override
  Widget build(BuildContext context) {
    Widget part(String label, String value, {Color? color}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label ', style: TWType.caption),
          Text(value,
              style: TWType.tabular(TWType.caption).copyWith(
                  fontWeight: FontWeight.w700,
                  color: color ?? TWColors.textSecondary)),
        ],
      );
    }

    final liq = match.liquidityScore;
    // Secondary to the hero Final Score pill: components + (Phase 11B) the
    // dominant liquidity contribution and a compact participation read-out.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 18,
          runSpacing: 4,
          children: [
            part('Base', match.effectiveBaseScore.toStringAsFixed(0)),
            if (liq != null)
              part('Liquidity', liq.toStringAsFixed(0),
                  color: liq >= 70
                      ? TWColors.up
                      : (liq < 40 ? TWColors.down : TWColors.textSecondary)),
            part('Bonus', '+${match.categoryBonus}',
                color: match.categoryBonus > 0
                    ? TWColors.up
                    : TWColors.textTertiary),
            part('Conviction', '${match.convictionScore}/20',
                color: match.convictionScore > 0
                    ? TWColors.up
                    : TWColors.textTertiary),
          ],
        ),
        if (match.hasLiquidityBreakdown) ...[
          const SizedBox(height: 4),
          _LiquidityLine(match: match),
        ],
      ],
    );
  }
}

/// Phase 11B: compact, secondary liquidity read-out under the breakdown.
/// "Rp 82B today · Rp 55B avg 20D · 2.4x vol". Money is abbreviated; missing
/// fields are simply skipped so old snapshots never crash or clutter the card.
class _LiquidityLine extends StatelessWidget {
  const _LiquidityLine({required this.match});
  final ScreenerMatch match;

  String _abbr(double v) {
    final a = v.abs();
    if (a >= 1e12) return '${(v / 1e12).toStringAsFixed(1)}T';
    if (a >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}B';
    if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (a >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (match.valueTradedToday != null) {
      parts.add('${_abbr(match.valueTradedToday!)} today');
    }
    if (match.avgValueTraded20d != null) {
      parts.add('${_abbr(match.avgValueTraded20d!)} avg 20D');
    }
    final vr = match.volumeRatio20d;
    if (vr != null && vr > 0) {
      parts.add('${vr.toStringAsFixed(1)}x vol');
    }
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join('  ·  '),
      key: const Key('screener_liquidity_line'),
      style: TWType.tabular(TWType.caption),
    );
  }
}

/// Phase 9A: a small Explore tag chip (Bullish, Silent Accumulation,
/// Strong CMF, Strong OBV, Strong ADX, ...).
class _ExploreTag extends StatelessWidget {
  const _ExploreTag({required this.label});
  final String label;

  bool get _isConviction =>
      label.startsWith('Strong ');

  @override
  Widget build(BuildContext context) {
    final color = _isConviction ? TWColors.up : TWColors.accentBright;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: TWSpace.sm, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: TWRadius.rChip,
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        style: TWType.caption.copyWith(
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _ScreenerError extends StatelessWidget {
  const _ScreenerError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: TWColors.down),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: TWType.body.copyWith(color: TWColors.textSecondary)),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _ScreenerEmpty extends StatelessWidget {
  const _ScreenerEmpty({
    required this.hasFilter,
    required this.onClearFilter,
    required this.onRefresh,
  });
  final bool hasFilter;
  final VoidCallback onClearFilter;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_alt_off_outlined,
                size: 48, color: TWColors.textTertiary),
            const SizedBox(height: 12),
            Text(
              hasFilter
                  ? 'No matches for this category.'
                  : 'No screener matches found.',
              textAlign: TextAlign.center,
              style: TWType.bodySm.copyWith(color: TWColors.textTertiary),
            ),
            const SizedBox(height: 16),
            if (hasFilter)
              FilledButton.tonal(
                onPressed: onClearFilter,
                child: const Text('Clear filter'),
              )
            else
              FilledButton.tonal(
                onPressed: onRefresh,
                child: const Text('Refresh'),
              ),
          ],
        ),
      ),
    );
  }
}
