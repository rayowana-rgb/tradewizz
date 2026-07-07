import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/broker.dart';
import '../models/market.dart';
import '../models/screener_category.dart';
import '../models/screener_result.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/data_source.dart';
import '../services/moomoo_secret_store.dart';
import '../services/repository_scope.dart';
import '../state/explore_filter_store.dart';
import '../theme_tradewizz.dart';
import '../widgets/category_badge.dart';
import '../widgets/connection_pill.dart';
import '../widgets/broker_open_sheet.dart';
import '../widgets/ds/ds.dart';
import 'ai_analysis_page.dart';
import 'moomoo_live_page.dart' show kMoomooOwnerUid;
import 'momentum_page.dart';
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
    this.secretStore,
    this.liveBulkOrderGap,
  });

  /// Market preselected from the app shell.
  final Market? market;
  final StockRepository? repository;

  /// Moomoo LIVE bridge secret store. Owner-only; backs the real "Buy all"
  /// action. Defaults to a real secure-storage store; tests inject a fake.
  final MoomooSecretStore? secretStore;

  /// In-memory filter persistence. Defaults to the process-wide singleton so
  /// selections survive tab switches; tests can inject a fresh store.
  final ExploreFilterStore? filterStore;

  /// Delay between LIVE bulk-buy order placements. Defaults to a value that
  /// keeps the run under Moomoo's ~15-orders / 30s rate limit; tests inject
  /// [Duration.zero] so they run instantly.
  final Duration? liveBulkOrderGap;

  @override
  State<ScreenerPage> createState() => _ScreenerPageState();
}

/// Default pacing for LIVE bulk-buy: Moomoo allows ~15 orders per 30s, so a
/// ~2.2s gap keeps us comfortably under the limit (≈ 13-14 orders / 30s).
const Duration _kDefaultLiveBulkOrderGap = Duration(milliseconds: 2200);

/// How long to wait after a transient rate-limit rejection before retrying
/// the same order (slightly longer than the 30s window edge can need).
const Duration _kLiveBulkRetryBackoff = Duration(seconds: 8);

/// Attempts per order (1 try + retries) when the broker rate-limits us.
const int _kLiveBulkMaxRetries = 3;

class _ScreenerPageState extends State<ScreenerPage> {
  late final StockRepository _repo = widget.repository ?? StockRepository();
  Duration get _liveBulkOrderGap =>
      widget.liveBulkOrderGap ?? _kDefaultLiveBulkOrderGap;
  ExploreFilterStore get _store =>
      widget.filterStore ?? ExploreFilterStore.instance;
  // Owner-only Moomoo LIVE bridge secret (secure-storage backed). Created
  // lazily; only the owner ever sees the LIVE bulk-buy entry point.
  late final MoomooSecretStore _moomooSecret =
      widget.secretStore ?? MoomooSecretStore();
  bool _moomooSecretLoaded = false;

  /// Whether the current user is the private-bridge owner (uid 2). Safe when
  /// no AuthScope is present (e.g. unit tests) — returns false instead of
  /// asserting.
  bool _isOwner() {
    final scope =
        context.getInheritedWidgetOfExactType<AuthScope>();
    final user = scope?.notifier?.user;
    return user != null && user.id == kMoomooOwnerUid;
  }

  /// LIVE bulk-buy is available only to the owner, on the US market (the only
  /// market the Moomoo bridge supports), once the bridge secret is loaded and
  /// present.
  bool _canLiveBuyAll() {
    return _isOwner() &&
        _market == Market.us &&
        _moomooSecretLoaded &&
        _moomooSecret.hasSecret;
  }

  late Market _market = widget.market ?? Market.idx;
  ScreenerCategory? _categoryFilter;
  double _minScore = 0;
  final _searchCtrl = TextEditingController();
  String _query = '';
  // Phase 10D extra filters (client-side, visual): signal + liquidity.
  String? _signalFilter; // BUY / HOLD / SELL
  bool _hideIlliquid = false;
  // Instrument-type filter: All / Stocks / ETFs (client-side, uses is_etf).
  InstrumentTypeFilter _instrumentType = InstrumentTypeFilter.all;
  // Tight-Stop Swing mode (client-side): re-rank by the server's swing_fit
  // score and keep only names with a workable fit for a -1% stop / +3%
  // target. Pure view-state; never changes scoring or the query.
  bool _swingMode = false;
  static const double _kSwingFitFloor = 60;
  // Phase 12 (Task C): a lightweight, non-persisted quick filter that keeps
  // only names clearing the strict TA confluence gate (trade_ready).
  bool _tradeReadyOnly = false;

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
      instrumentType: _instrumentType,
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
      _instrumentType = _store.instrumentType;
      _query = _store.query;
      _searchCtrl.text = _store.query;
      // The shell still owns the market; only fall back to the stored market
      // when the shell didn't pass one.
      if (widget.market == null && _store.market != null) {
        _market = _store.market!;
      }
    }
    // Owner-only: load the LIVE bridge secret in the background so the real
    // "Buy all" entry point can appear. No-op for non-owners (they never see
    // it). Failure simply leaves the LIVE action hidden.
    _moomooSecret.load().then((_) {
      if (mounted) setState(() => _moomooSecretLoaded = true);
    }).catchError((_) {
      if (mounted) setState(() => _moomooSecretLoaded = true);
    });
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
    // The dialog can request cancellation (tap outside / back); when confirmed
    // it flips this token so the loop stops after the current order.
    final progress = ValueNotifier<int>(0);
    final cancel = _BulkCancelToken();
    showDialog<void>(
      context: context,
      // We handle dismissal ourselves so we can confirm "stop the purchase?".
      barrierDismissible: false,
      builder: (_) => _BulkProgressDialog(
        total: matches.length,
        progress: progress,
        cancel: cancel,
      ),
    );

    var cancelled = false;
    for (var i = 0; i < matches.length; i++) {
      if (cancel.isCancelled) {
        cancelled = true;
        break;
      }
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
    // Close the progress dialog only if it is still up (a confirmed cancel may
    // have already popped it).
    if (!cancel.dialogClosed) {
      Navigator.of(context, rootNavigator: true).pop();
    }

    await showDialog<void>(
      context: context,
      builder: (_) => _BulkResultDialog(
        total: matches.length,
        filled: filled,
        skipped: skipped,
        failed: failed,
        failures: failures,
        cancelled: cancelled,
      ),
    );
  }

  /// Owner-only: open the REAL (Moomoo LIVE) bulk-buy sheet for every stock in
  /// the filtered list. Guarded by [_canLiveBuyAll]. Orders are MARKET only
  /// (the bridge allows fractional MARKET; LIMIT needs whole shares + price).
  Future<void> _openLiveBulkBuy() async {
    final matches = _filtered;
    if (matches.isEmpty) return;
    final token = AuthScope.read(context).token;
    final secret = _moomooSecret.secret;
    if (token == null || secret == null || secret.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('LIVE trading is unavailable (missing credentials).'),
        ),
      );
      return;
    }

    // Skip names we shouldn't re-buy: (a) currently held positions, and
    // (b) anything already bought today even if no longer held (e.g. bought
    // then sold the same day) so a "Buy all" never doubles up within a day.
    // Each fetch is best-effort: a failure must not block the run (we just
    // skip less rather than spending nothing).
    final repo = widget.repository ?? RepositoryScope.of(context);
    final skipSymbols = <String>{};
    try {
      final positions = await repo.moomooPositions(
        token: token,
        secret: secret,
      );
      skipSymbols.addAll(positions
          .where((p) => p.quantity > 0)
          .map((p) => p.symbol.toUpperCase()));
    } catch (_) {
      /* proceed without held-skip on a positions fetch failure */
    }
    try {
      final boughtToday = await repo.moomooBoughtToday(
        token: token,
        secret: secret,
      );
      skipSymbols.addAll(boughtToday);
    } catch (_) {
      /* proceed without bought-today-skip on a fetch failure */
    }
    if (!mounted) return;

    final buyable = skipSymbols.isEmpty
        ? matches
        : matches
            .where((m) => !skipSymbols.contains(m.symbol.toUpperCase()))
            .toList();
    final alreadyHeld = matches.length - buyable.length;

    if (buyable.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(alreadyHeld == 1
              ? 'Nothing to buy: the only match is already held or '
                  'bought today.'
              : 'Nothing to buy: all $alreadyHeld matches are already held '
                  'or bought today.'),
        ),
      );
      return;
    }

    final config = await showModalBottomSheet<_LiveBulkBuyConfig>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LiveBulkBuySheet(
        market: _market,
        count: buyable.length,
        alreadyHeld: alreadyHeld,
      ),
    );
    if (!mounted || config == null) return;
    // Cap the run to the top-N the owner selected on the slider (the list is
    // already ranked, so take() keeps the highest-ranked names).
    final selected = config.topN >= buyable.length
        ? buyable
        : buyable.take(config.topN).toList();
    await _runLiveBulkBuy(selected, config, token, secret);
  }

  /// Place a REAL Moomoo LIVE MARKET BUY for each match sequentially. Backend
  /// enforces the per-order notional cap, kill-switch and owner gate; the
  /// per-order outcome is summarised: filled / skipped (cap/cash) / failed.
  Future<void> _runLiveBulkBuy(
    List<ScreenerMatch> matches,
    _LiveBulkBuyConfig config,
    String token,
    String secret,
  ) async {
    final repo = widget.repository ?? RepositoryScope.of(context);
    var filled = 0;
    var skipped = 0;
    var failed = 0;
    final failures = <String>[];

    final progress = ValueNotifier<int>(0);
    final cancel = _BulkCancelToken();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BulkProgressDialog(
        total: matches.length,
        progress: progress,
        cancel: cancel,
        live: true,
      ),
    );

    var cancelled = false;
    for (var i = 0; i < matches.length; i++) {
      if (cancel.isCancelled) {
        cancelled = true;
        break;
      }
      final m = matches[i];
      final qty = config.quantityFor(m.price);
      if (qty == null) {
        // Cannot size this order (e.g. missing price in dollar mode): skip.
        skipped++;
        progress.value = i + 1;
        continue;
      }

      // Moomoo throttles placement to ~15 orders / 30s. Pace ourselves so a
      // large "Buy all" run does not trip the broker's rate limiter (which
      // previously caused everything after the 15th order to fail).
      if (i > 0 && _liveBulkOrderGap > Duration.zero) {
        await Future<void>.delayed(_liveBulkOrderGap);
      }

      var outcome = 0; // 0=filled, 1=skipped, 2=failed
      String? failMsg;
      // Up to a few attempts so a transient rate-limit hit is retried with
      // backoff rather than counted as a hard failure.
      for (var attempt = 0; attempt < _kLiveBulkMaxRetries; attempt++) {
        if (cancel.isCancelled) break;
        try {
          await repo.moomooPlace(
            token: token,
            secret: secret,
            symbol: m.symbol,
            side: 'BUY',
            quantity: qty,
            orderType: 'MARKET',
          );
          outcome = 0;
          break;
        } on ApiException catch (e) {
          final msg = e.message.toLowerCase();
          // Transient broker rate limit: wait out the window and retry the
          // same order instead of dropping it.
          if (msg.contains('high frequency') ||
              msg.contains('per 30 seconds') ||
              msg.contains('rate limit') ||
              msg.contains('too many requests')) {
            outcome = 2;
            failMsg = e.message;
            if (attempt < _kLiveBulkMaxRetries - 1) {
              // Skip the backoff entirely when pacing is disabled (tests).
              if (_liveBulkOrderGap > Duration.zero) {
                await Future<void>.delayed(_kLiveBulkRetryBackoff);
              }
              continue;
            }
            break;
          }
          // Expected, non-fatal per-stock outcomes from the broker: skip &
          // continue the run instead of flagging a hard failure. Covers our
          // own cap/cash guards plus two common Moomoo broker rejections:
          //   * fractional orders below the $1 minimum order amount, and
          //   * names that need a MAS (Singapore) suitability evaluation.
          if (msg.contains('cap') ||
              msg.contains('notional') ||
              msg.contains('cash') ||
              msg.contains('buying power') ||
              msg.contains('minimum order amount') ||
              (msg.contains('fractional') && msg.contains('minimum')) ||
              msg.contains('monetary authority') ||
              msg.contains('complete the evaluation')) {
            outcome = 1;
          } else {
            outcome = 2;
            failMsg = e.message;
          }
          break;
        } catch (e) {
          outcome = 2;
          failMsg = '$e';
          break;
        }
      }

      if (outcome == 0) {
        filled++;
      } else if (outcome == 1) {
        skipped++;
      } else {
        failed++;
        failures.add('${m.symbol}: ${failMsg ?? 'failed'}');
      }
      progress.value = i + 1;
    }

    progress.dispose();
    if (!mounted) return;
    if (!cancel.dialogClosed) {
      Navigator.of(context, rootNavigator: true).pop();
    }

    await showDialog<void>(
      context: context,
      builder: (_) => _BulkResultDialog(
        total: matches.length,
        filled: filled,
        skipped: skipped,
        failed: failed,
        failures: failures,
        cancelled: cancelled,
        live: true,
      ),
    );
  }

  // Server already filters; keep a defensive local pass for fallback data.
  List<ScreenerMatch> get _filtered {
    final matches = _result?.matches ?? [];
    final q = _query.trim().toUpperCase();
    final out = matches.where((m) {
      if (_swingMode && m.effectiveSwingFit < _kSwingFitFloor) return false;
      if (_tradeReadyOnly && !m.tradeReady) return false;
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
      if (_instrumentType == InstrumentTypeFilter.stock && m.isEtf) {
        return false;
      }
      if (_instrumentType == InstrumentTypeFilter.etf && !m.isEtf) {
        return false;
      }
      if (q.isNotEmpty &&
          !m.symbol.toUpperCase().contains(q) &&
          !m.name.toUpperCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
    // In swing mode, re-rank by the tight-stop fit (best setup first); the
    // server's default ranking is by Final Explore Score.
    if (_swingMode) {
      out.sort((a, b) => b.effectiveSwingFit.compareTo(a.effectiveSwingFit));
    } else {
      // Keep the server's Final-Score order but float trade-ready names to the
      // top of equal-score groups so the strongest setups lead (stable sort).
      out.sort((a, b) {
        if (a.tradeReady != b.tradeReady) return a.tradeReady ? -1 : 1;
        return b.effectiveFinalScore.compareTo(a.effectiveFinalScore);
      });
    }
    return out;
  }

  int get _activeFilterCount {
    var n = 0;
    if (_categoryFilter != null) n++;
    if (_minScore > 0) n++;
    if (_signalFilter != null) n++;
    if (_hideIlliquid) n++;
    if (_instrumentType != InstrumentTypeFilter.all) n++;
    if (_swingMode) n++;
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
        instrumentType: _instrumentType,
        swingMode: _swingMode,
        onApply: (m, cat, min, sig, hide, type, swing) {
          setState(() {
            _market = m;
            _categoryFilter = cat;
            _minScore = min;
            _signalFilter = sig;
            _hideIlliquid = hide;
            _instrumentType = type;
            _swingMode = swing;
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
        // Phase 12 (Task C): a quick "Trade-ready" filter -- names that clear
        // the strict TA confluence gate (uptrend + healthy RSI + broad
        // confirmation). Descriptive, not a prediction.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              FilterChip(
                key: const Key('screener_trade_ready_filter'),
                selected: _tradeReadyOnly,
                label: const Text('Trade-ready only'),
                avatar: Icon(Icons.bolt,
                    size: 15,
                    color: _tradeReadyOnly
                        ? TWColors.bgBase
                        : TWColors.up),
                selectedColor: TWColors.up,
                checkmarkColor: TWColors.bgBase,
                labelStyle: TWType.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color:
                      _tradeReadyOnly ? TWColors.bgBase : TWColors.textSecondary,
                ),
                backgroundColor: TWColors.surfaceCard,
                onSelected: (v) => setState(() => _tradeReadyOnly = v),
              ),
            ],
          ),
        ),
        // Momentum Research entry (EXPERIMENTAL, Stage-3b). Opens the dedicated
        // 12-1 momentum picks page. US-only research signal; honestly labelled.
        _MomentumEntryBanner(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MomentumPage(
                  repository: _repo,
                  secretStore: _moomooSecret,
                  ownerUid: AuthScope.read(context).user?.id,
                ),
              ),
            );
          },
        ),
        // Sentiment (category) chips and the Tight-Stop Swing toggle now live
        // inside the Filters sheet. When swing mode is active we keep a compact
        // inline note so the (re-ranked) results still read clearly.
        if (_swingMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              'Ranked by Tight-Stop Swing fit (-1% stop / +3% target). '
              'A fit gauge, not a probability.',
              style: TWType.caption.copyWith(color: TWColors.textTertiary),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
            onLiveBuyAll: _canLiveBuyAll() ? _openLiveBulkBuy : null,
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
    // Clear the floating glass nav bar (60px) plus the device safe-area inset
    // so the footer's "Load more" control is never hidden behind it.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return RefreshIndicator(
      onRefresh: _run,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(16, 12, 16, TWSpace.xxxxl + bottomInset),
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
                swingMode: _swingMode,
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

/// Immutable result of the LIVE bulk-buy sheet: quantity-per-stock. LIVE bulk
/// orders are MARKET only (fractional allowed), so there is no order-type.
/// How a LIVE bulk buy sizes each order.
///   * [shares]  — the same fractional share quantity for every stock.
///   * [dollars] — a fixed dollar amount per stock; the per-stock share
///     quantity is derived from each stock's price (amount / price). This
///     avoids Moomoo's \$1 minimum-order rejection as long as the amount is
///     at least \$1.
enum _LiveBulkSizing { shares, dollars }

class _LiveBulkBuyConfig {
  const _LiveBulkBuyConfig({
    required this.sizing,
    required this.topN,
    this.quantity = 0,
    this.dollarAmount = 0,
  });

  /// How many of the top-ranked buyable matches to actually buy (1..count).
  final int topN;

  /// Fixed share quantity per stock (used when [sizing] is shares).
  final double quantity;

  /// Fixed dollar amount per stock (used when [sizing] is dollars).
  final double dollarAmount;

  final _LiveBulkSizing sizing;

  /// Resolve the share quantity for a stock trading at [price]. Returns null
  /// when the order cannot be sized (e.g. a missing/zero price in dollar mode).
  double? quantityFor(double price) {
    if (sizing == _LiveBulkSizing.shares) return quantity;
    if (price <= 0) return null;
    // Round to 4 dp — Moomoo accepts fractional MARKET orders; this keeps the
    // notional close to the requested dollar amount without odd precision.
    final q = dollarAmount / price;
    final rounded = (q * 10000).round() / 10000;
    return rounded > 0 ? rounded : null;
  }
}

/// Owner-only confirmation sheet for a REAL (Moomoo LIVE) bulk buy. Requires an
/// explicit "I understand" toggle before the action can run, because every
/// order spends real money. MARKET orders only; the backend enforces the
/// per-order notional cap and kill-switch.
class _LiveBulkBuySheet extends StatefulWidget {
  const _LiveBulkBuySheet({
    required this.market,
    required this.count,
    this.alreadyHeld = 0,
  });
  final Market market;
  final int count;
  // Number of matches dropped from this run because they are already held.
  final int alreadyHeld;

  @override
  State<_LiveBulkBuySheet> createState() => _LiveBulkBuySheetState();
}

class _LiveBulkBuySheetState extends State<_LiveBulkBuySheet> {
  final _qtyController = TextEditingController(text: '1');
  final _dollarController = TextEditingController(text: '5');
  final _formKey = GlobalKey<FormState>();
  bool _acknowledged = false;
  _LiveBulkSizing _sizing = _LiveBulkSizing.shares;
  // How many of the top-ranked matches to buy. Defaults to all of them; the
  // slider lets the owner cap the run to the top 1..count.
  late int _topN = widget.count;

  @override
  void dispose() {
    _qtyController.dispose();
    _dollarController.dispose();
    super.dispose();
  }

  _LiveBulkBuyConfig? _buildConfig() {
    if (!_formKey.currentState!.validate()) return null;
    if (_sizing == _LiveBulkSizing.dollars) {
      return _LiveBulkBuyConfig(
        sizing: _LiveBulkSizing.dollars,
        topN: _topN,
        dollarAmount: double.parse(
            _dollarController.text.trim().replaceAll(',', '.')),
      );
    }
    return _LiveBulkBuyConfig(
      sizing: _LiveBulkSizing.shares,
      topN: _topN,
      quantity:
          double.parse(_qtyController.text.trim().replaceAll(',', '.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Form(
          key: _formKey,
          // Scrollable so the numeric keypad can never hide the Confirm button;
          // the user can always scroll down to it (or tap outside to dismiss).
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.bolt_rounded, color: TWColors.down),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _topN >= widget.count
                          ? 'Buy all ${widget.count} · LIVE'
                          : 'Buy top $_topN · LIVE',
                      key: const Key('live_bulk_title'),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.market.flag} ${widget.market.code} · REAL MONEY. The '
                'same quantity is bought for every stock in the current list '
                'as a MARKET order on your live Moomoo account. Moomoo rejects '
                'fractional orders worth under \$1, names pending a Moomoo '
                'suitability evaluation, and orders over the cap or short on '
                'buying power — those are skipped, not failed.',
                style: const TextStyle(
                    color: TWColors.textTertiary, fontSize: 12),
              ),
              if (widget.alreadyHeld > 0) ...[
                const SizedBox(height: 8),
                Text(
                  widget.alreadyHeld == 1
                      ? '1 match is already held or bought today and was '
                          'skipped.'
                      : '${widget.alreadyHeld} matches are already held or '
                          'bought today and were skipped.',
                  key: const Key('live_bulk_already_held'),
                  style: const TextStyle(
                      color: TWColors.warn,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ],
              if (widget.count > 1) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'How many to buy',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      _topN >= widget.count ? 'All ${widget.count}' : 'Top $_topN',
                      key: const Key('live_bulk_topn_label'),
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: TWColors.accentBright),
                    ),
                  ],
                ),
                Slider(
                  key: const Key('live_bulk_topn_slider'),
                  min: 1,
                  max: widget.count.toDouble(),
                  divisions: widget.count - 1,
                  value: _topN.toDouble(),
                  label: '$_topN',
                  activeColor: TWColors.accent,
                  onChanged: (v) => setState(() => _topN = v.round()),
                ),
                Text(
                  'Slide right for more. Buys the top $_topN highest-ranked '
                  '${_topN == 1 ? 'match' : 'matches'} from the current list.',
                  style: const TextStyle(
                      color: TWColors.textTertiary, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              SegmentedButton<_LiveBulkSizing>(
                key: const Key('live_bulk_sizing_toggle'),
                segments: const [
                  ButtonSegment(
                    value: _LiveBulkSizing.shares,
                    label: Text('Shares'),
                    icon: Icon(Icons.tag, size: 16),
                  ),
                  ButtonSegment(
                    value: _LiveBulkSizing.dollars,
                    label: Text('\$ / stock'),
                    icon: Icon(Icons.attach_money, size: 16),
                  ),
                ],
                selected: {_sizing},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setState(() => _sizing = s.first),
              ),
              const SizedBox(height: 12),
              if (_sizing == _LiveBulkSizing.shares)
                TextFormField(
                  key: const Key('live_bulk_qty_field'),
                  controller: _qtyController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [_DecimalQtyFormatter()],
                  // The numeric keypad has no return key on iOS; let a tap
                  // anywhere outside the field dismiss it so it stops covering
                  // the Confirm button.
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                  decoration: const InputDecoration(
                    labelText: 'Quantity per stock (fractional allowed)',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final q = double.tryParse(
                        (v ?? '').trim().replaceAll(',', '.'));
                    if (q == null || q <= 0) {
                      return 'Enter a positive quantity';
                    }
                    return null;
                  },
                )
              else
                TextFormField(
                  key: const Key('live_bulk_dollar_field'),
                  controller: _dollarController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [_DecimalQtyFormatter()],
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                  decoration: const InputDecoration(
                    labelText: 'Amount per stock (USD)',
                    prefixText: '\$ ',
                    helperText:
                        'Shares = amount ÷ price. Keep ≥ \$1 to clear '
                        'Moomoo\'s minimum.',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final d = double.tryParse(
                        (v ?? '').trim().replaceAll(',', '.'));
                    if (d == null || d <= 0) {
                      return 'Enter a positive amount';
                    }
                    if (d < 1) return 'Use at least \$1 per stock';
                    return null;
                  },
                ),
              const SizedBox(height: 14),
              CheckboxListTile(
                key: const Key('live_bulk_ack'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _acknowledged,
                activeColor: TWColors.down,
                onChanged: (v) =>
                    setState(() => _acknowledged = v ?? false),
                title: const Text(
                  'I understand these are real orders that spend real money.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('live_bulk_confirm_button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: TWColors.down,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _acknowledged
                      ? () {
                          final cfg = _buildConfig();
                          if (cfg == null) return;
                          Navigator.of(context).pop(cfg);
                        }
                      : null,
                  child: Text(_topN >= widget.count
                      ? 'Buy all ${widget.count} · LIVE'
                      : 'Buy top $_topN · LIVE'),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// Slim action bar above the list: "Buy all (N)" — simulation bulk entry point.
/// When [onLiveBuyAll] is provided (owner, on a Moomoo-tradable market), a
/// second REAL-money "Buy all · LIVE" button is shown below the simulated one.
class _BulkActionBar extends StatelessWidget {
  const _BulkActionBar({
    required this.count,
    required this.onBuyAll,
    this.onLiveBuyAll,
  });
  final int count;
  final VoidCallback onBuyAll;
  final VoidCallback? onLiveBuyAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('screener_buy_all_button'),
              onPressed: onBuyAll,
              style: FilledButton.styleFrom(
                backgroundColor: TWColors.up,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape:
                    RoundedRectangleBorder(borderRadius: TWRadius.rButton),
              ),
              icon: const Icon(Icons.shopping_cart_checkout_rounded,
                  size: 18),
              label: Text('Buy all ($count) · simulated'),
            ),
          ),
          if (onLiveBuyAll != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('screener_buy_all_live_button'),
                onPressed: onLiveBuyAll,
                style: FilledButton.styleFrom(
                  backgroundColor: TWColors.down,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: TWRadius.rButton),
                ),
                icon: const Icon(Icons.bolt_rounded, size: 18),
                label: Text('Buy all ($count) · LIVE (real money)'),
              ),
            ),
          ],
        ],
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
        // Comfortable top padding so the header isn't cramped right under the
        // drag handle (it used to hug the very top). Gives the sheet a more
        // centered, premium feel.
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Form(
          key: _formKey,
          // Scrollable so the numeric keypad never hides the Confirm button.
          child: SingleChildScrollView(
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
                // Tap outside dismisses the numeric keypad (no return key).
                onTapOutside: (_) => FocusScope.of(context).unfocus(),
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
      ),
    );
  }
}

/// Modal progress while the bulk run places one order at a time.
/// Shared mutable flag the progress dialog flips when the user confirms they
/// want to stop a running bulk buy. The order loop checks [isCancelled] before
/// each order; [dialogClosed] tells the caller whether the dialog already
/// popped itself (so it isn't popped twice).
class _BulkCancelToken {
  bool isCancelled = false;
  bool dialogClosed = false;
}

class _BulkProgressDialog extends StatefulWidget {
  const _BulkProgressDialog({
    required this.total,
    required this.progress,
    required this.cancel,
    this.live = false,
  });
  final int total;
  final ValueNotifier<int> progress;
  final _BulkCancelToken cancel;
  final bool live;

  @override
  State<_BulkProgressDialog> createState() => _BulkProgressDialogState();
}

class _BulkProgressDialogState extends State<_BulkProgressDialog> {
  bool _stopping = false;

  /// Ask the user to confirm stopping. Returns true if they chose "Yes".
  Future<bool> _confirmStop() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('bulk_cancel_confirm'),
        title: const Text('Stop the purchase?'),
        content: const Text(
          'Orders already placed will stay. The remaining orders won\u2019t '
          'be placed.',
        ),
        actions: [
          TextButton(
            key: const Key('bulk_cancel_no'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            key: const Key('bulk_cancel_yes'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    return yes ?? false;
  }

  Future<void> _requestCancel() async {
    if (_stopping) return;
    final yes = await _confirmStop();
    if (!mounted) return;
    if (yes) {
      setState(() => _stopping = true);
      widget.cancel.isCancelled = true;
      // Close the progress dialog now; the loop will break and the summary
      // dialog (reflecting what was placed) follows.
      widget.cancel.dialogClosed = true;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Catch the system back gesture/button and route it through the same
    // confirm flow instead of dismissing silently.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestCancel();
      },
      child: Stack(
        children: [
          // A transparent full-screen layer so a tap *outside* the card opens
          // the "stop the purchase?" confirmation rather than doing nothing.
          Positioned.fill(
            child: GestureDetector(
              key: const Key('bulk_progress_barrier'),
              behavior: HitTestBehavior.opaque,
              onTap: _requestCancel,
            ),
          ),
          Center(
            child: AlertDialog(
              key: const Key('bulk_progress_dialog'),
              content: ValueListenableBuilder<int>(
                valueListenable: widget.progress,
                builder: (context, done, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: widget.total == 0 ? null : done / widget.total,
                      color: widget.live ? TWColors.down : TWColors.up,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _stopping
                          ? 'Stopping\u2026  $done / ${widget.total}'
                          : widget.live
                              ? 'Placing LIVE orders\u2026  $done / ${widget.total}'
                              : 'Placing simulated orders\u2026  $done / ${widget.total}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tap outside to stop.',
                      style: TextStyle(
                          fontSize: 11, color: TWColors.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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
    this.cancelled = false,
    this.live = false,
  });
  final int total;
  final int filled;
  final int skipped;
  final int failed;
  final List<String> failures;
  final bool cancelled;
  final bool live;

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
      title: Text(cancelled
          ? (live ? 'LIVE buy stopped' : 'Bulk buy stopped')
          : (live ? 'LIVE buy complete' : 'Bulk buy complete')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line(Icons.check_circle, TWColors.up,
              live ? '$filled placed (LIVE)' : '$filled filled (simulated)'),
          if (skipped > 0)
            line(
                Icons.account_balance_wallet_outlined,
                TWColors.warn,
                live
                    ? '$skipped skipped — under \$1 min, cap, buying power, '
                        'or pending Moomoo evaluation'
                    : '$skipped skipped — not enough simulated cash'),
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
          Text(
            live
                ? 'LIVE orders were sent to your real Moomoo account.'
                : 'Simulation only. No real broker orders were sent.',
            style: const TextStyle(
                fontSize: 12, color: TWColors.textTertiary),
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

/// Explore entry point for the EXPERIMENTAL momentum research signal. A slim
/// tappable banner that opens the dedicated [MomentumPage]. Kept intentionally
/// distinct (accent + science glyph) so it reads as research, not a screener
/// category.
class _MomentumEntryBanner extends StatelessWidget {
  const _MomentumEntryBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: TWColors.surfaceCardGlass,
        borderRadius: BorderRadius.circular(TWRadius.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(TWRadius.card),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: TWSpace.lg, vertical: TWSpace.md),
            child: Row(
              children: [
                const Icon(Icons.trending_up,
                    color: TWColors.accent, size: 20),
                const SizedBox(width: TWSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('Momentum Research', style: TWType.label),
                          const SizedBox(width: TWSpace.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: TWColors.warn.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(TWRadius.sm),
                            ),
                            child: Text('EXPERIMENTAL',
                                style: TWType.overline
                                    .copyWith(color: TWColors.warn)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text('Top US 12-1 momentum · monthly hold (Stage-3b)',
                          style: TWType.caption
                              .copyWith(color: TWColors.textTertiary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right,
                    color: TWColors.textTertiary, size: 20),
              ],
            ),
          ),
        ),
      ),
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
      // Tightened to sit closer under the search field (was top 12) while
      // keeping a small breathing gap.
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
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
    required this.instrumentType,
    required this.swingMode,
    required this.onApply,
  });

  final Market market;
  final ScreenerCategory? category;
  final double minScore;
  final String? signal;
  final bool hideIlliquid;
  final InstrumentTypeFilter instrumentType;
  final bool swingMode;
  final void Function(
    Market market,
    ScreenerCategory? category,
    double minScore,
    String? signal,
    bool hideIlliquid,
    InstrumentTypeFilter instrumentType,
    bool swingMode,
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
  late InstrumentTypeFilter _instrumentType = widget.instrumentType;
  late bool _swingMode = widget.swingMode;

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
              _label('Strategy'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    key: const Key('screener_swing_mode'),
                    selected: _swingMode,
                    label: Text(
                      _swingMode
                          ? 'Tight-Stop Swing · -1% / +3%'
                          : 'Tight-Stop Swing',
                    ),
                    avatar: Icon(
                      Icons.bolt_rounded,
                      size: 16,
                      color: _swingMode
                          ? TWColors.surfaceCard
                          : TWColors.textTertiary,
                    ),
                    selectedColor: TWColors.accent,
                    checkmarkColor: TWColors.surfaceCard,
                    onSelected: (v) => setState(() => _swingMode = v),
                  ),
                ],
              ),
              if (_swingMode)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Ranked for a -1% stop / +3% target: moderate volatility '
                    "(so -1% isn't pure noise), an established up-trend, and "
                    'healthy, not-overbought momentum. A fit gauge, not a '
                    'probability.',
                    style:
                        TWType.caption.copyWith(color: TWColors.textTertiary),
                  ),
                ),
              const SizedBox(height: 14),
              _label('Min Score'),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in const <double>[0, 50, 70, 80, 90])
                    ChoiceChip(
                      selected: v == _minScore,
                      label: Text(v == 0 ? 'Any' : '≥ ${v.toInt()}'),
                      onSelected: (_) => setState(() => _minScore = v),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _label('Type'),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in InstrumentTypeFilter.values)
                    ChoiceChip(
                      key: Key('screener_type_${t.name}'),
                      selected: t == _instrumentType,
                      label: Text(t.label),
                      onSelected: (_) =>
                          setState(() => _instrumentType = t),
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
                        _instrumentType = InstrumentTypeFilter.all;
                        _swingMode = false;
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
                            _signal, _hideIlliquid, _instrumentType,
                            _swingMode);
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
  const _MatchCard({required this.match, this.onTap, this.swingMode = false});
  final ScreenerMatch match;
  final VoidCallback? onTap;
  final bool swingMode;

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
            // Tight-Stop Swing: when the mode is on, surface the fit gauge +
            // ATR% so the basis for the ranking is visible (no hidden magic).
            if (swingMode && match.hasSwingFit) ...[
              const SizedBox(height: 10),
              _SwingFitBar(match: match),
            ],
            // Phase 9A: Explore score breakdown (Final = Base + Bonus +
            // Conviction). Only shown when the server sent the overlay.
            if (match.finalScore != null) ...[
              const SizedBox(height: 10),
              _ScoreBreakdown(match: match),
            ],
            // Phase 12 (Task A + C): technical-confirmation transparency. Show
            // a Trade-ready chip when the strict confluence gate is cleared and
            // an "N/M confirmations" summary with the reasons that fired, so the
            // user can see WHY a name is bullish -- not just a score.
            if (match.hasConfirmationBreakdown &&
                match.confirmationsFired > 0) ...[
              const SizedBox(height: 10),
              _ConfirmationsBlock(match: match),
            ],
            if (match.exploreTags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (match.tradeReady) const _TradeReadyChip(),
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

/// Tight-Stop Swing fit bar: shows the 0..100 fit gauge for a -1% stop /
/// +3% target plus the ATR% (typical daily move) so the user can sanity-check
/// how much noise a -1% stop has to survive. A fit gauge, not a probability.
class _SwingFitBar extends StatelessWidget {
  const _SwingFitBar({required this.match});
  final ScreenerMatch match;

  @override
  Widget build(BuildContext context) {
    final fit = match.effectiveSwingFit;
    final color = TWColors.confidence(fit);
    final atr = match.atrPct;
    // A -1% stop sits inside one day's noise band when ATR% is high; flag it.
    final atrTight = atr != null && atr > 3.0;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.md, vertical: TWSpace.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: TWRadius.rSm,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt_rounded, size: 16, color: color),
          const SizedBox(width: 6),
          Text('Swing fit', style: TWType.caption),
          const SizedBox(width: 6),
          Text(
            fit.toStringAsFixed(0),
            style: TWType.tabular(TWType.label).copyWith(color: color),
          ),
          const Spacer(),
          if (atr != null)
            Text(
              'ATR ${atr.toStringAsFixed(1)}%',
              style: TWType.tabular(TWType.caption).copyWith(
                color: atrTight ? TWColors.warn : TWColors.textTertiary,
              ),
            ),
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

/// Phase 12 (Task C): a distinct chip flagging a name that clears the strict
/// TA confluence gate (bullish + uptrend structure + healthy RSI + broad
/// confirmation). Descriptive of the current posture, NOT a prediction.
class _TradeReadyChip extends StatelessWidget {
  const _TradeReadyChip();

  @override
  Widget build(BuildContext context) {
    const color = TWColors.up;
    return Container(
      key: const Key('screener_trade_ready_chip'),
      padding: const EdgeInsets.symmetric(horizontal: TWSpace.sm, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.20),
        borderRadius: TWRadius.rChip,
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt, size: 13, color: color),
          const SizedBox(width: 3),
          Text(
            'Trade-ready',
            style: TWType.caption
                .copyWith(fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}

/// Phase 12 (Task A): the technical-confirmation breakdown. A compact
/// "N/M confirmations" header plus the human-readable reasons that fired, so
/// the Explore card shows WHY a name is bullish instead of only a score.
class _ConfirmationsBlock extends StatelessWidget {
  const _ConfirmationsBlock({required this.match});
  final ScreenerMatch match;

  @override
  Widget build(BuildContext context) {
    final fired = match.confirmationsFired;
    final total = match.confirmationsTotal;
    // Strength colour: green when most confirmations fire, amber mid, grey low.
    final ratio = total > 0 ? fired / total : 0.0;
    final color = ratio >= 0.6
        ? TWColors.up
        : (ratio >= 0.35 ? TWColors.warn : TWColors.textTertiary);
    final reasons = match.convictionReasons;
    return Column(
      key: const Key('screener_confirmations_block'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.verified_outlined, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              '$fired/$total technical confirmations',
              style: TWType.caption
                  .copyWith(fontWeight: FontWeight.w700, color: color),
            ),
          ],
        ),
        if (reasons.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final r in reasons)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check,
                        size: 12, color: TWColors.textTertiary),
                    const SizedBox(width: 2),
                    Text(r,
                        style: TWType.caption
                            .copyWith(color: TWColors.textSecondary)),
                  ],
                ),
            ],
          ),
        ],
      ],
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

// Normalizes decimal input for the LIVE bulk-buy quantity field: ID/EU
// keyboards emit a comma decimal separator; convert it to a dot and keep only
// the first separator so "0,001" parses as 0.001 (not 0001).
class _DecimalQtyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    var text = newValue.text.replaceAll(',', '.');
    final firstDot = text.indexOf('.');
    if (firstDot != -1) {
      final head = text.substring(0, firstDot + 1);
      final tail = text.substring(firstDot + 1).replaceAll('.', '');
      text = head + tail;
    }
    if (text == newValue.text) return newValue;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
