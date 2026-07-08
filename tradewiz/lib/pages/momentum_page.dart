import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/momentum.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart' show ApiException;
import '../services/auth_scope.dart';
import '../services/keep_awake.dart';
import '../services/moomoo_secret_store.dart';
import '../theme_tradewizz.dart';
import '../widgets/ds/ds.dart';
import 'momentum_holdings_page.dart';
import 'strategy_comparison_page.dart';
import 'moomoo_live_page.dart' show kMoomooOwnerUid;

/// Momentum Research (EXPERIMENTAL, Stage-3b).
///
/// Surfaces the long-only 12-1 cross-sectional momentum concept that passed the
/// research institute's historical out-of-sample gate (excess TEST t=2.49) but
/// is NOT live-validated. Read-only picks for everyone; a one-tap real-money
/// basket buy for the owner only.
///
/// Exit rule is deliberately NOT a tight stop: these are monthly-hold positions
/// (rebalance is the exit). The app's SL-1%/TP+3% swing config was proven to
/// destroy the momentum edge, so it is not used here.
class MomentumPage extends StatefulWidget {
  const MomentumPage({
    super.key,
    required this.repository,
    required this.secretStore,
    this.ownerUid,
  });

  final StockRepository repository;
  final MoomooSecretStore secretStore;

  /// Signed-in uid; the basket-buy CTA only appears for [kMoomooOwnerUid].
  final int? ownerUid;

  @override
  State<MomentumPage> createState() => _MomentumPageState();
}

class _MomentumPageState extends State<MomentumPage> {
  MomentumPicks? _picks;
  bool _loading = true;
  String? _error;
  final int _topN = 10;

  // Manual sizing. Defaults to a conservative per-position amount; the owner
  // types the real figure. Nothing is fixed on their behalf.
  final _sizeCtrl = TextEditingController(text: '250');

  bool get _isOwner => widget.ownerUid == kMoomooOwnerUid;

  @override
  void initState() {
    super.initState();
    widget.secretStore.load();
    _refresh();
  }

  @override
  void dispose() {
    _sizeCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.repository.momentumPicks(topN: _topN);
      if (!mounted) return;
      setState(() {
        _picks = p;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load momentum picks. $e';
        _loading = false;
      });
    }
  }

  double? get _perPosition {
    final v = double.tryParse(_sizeCtrl.text.trim());
    if (v == null || v <= 0) return null;
    return v;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TWColors.bgBase,
      appBar: AppBar(
        backgroundColor: TWColors.bgBase,
        elevation: 0,
        title: const Text('Momentum Research', style: TWType.body),
        actions: [
          if (_isOwner)
            IconButton(
              icon: const Icon(Icons.insights_outlined),
              tooltip: 'Strategy comparison',
              onPressed: _openComparison,
            ),
          if (_isOwner)
            IconButton(
              icon: const Icon(Icons.account_balance_wallet_outlined),
              tooltip: 'Momentum holdings',
              onPressed: _openHoldings,
            ),
        ],
      ),
      // Dismiss the number pad when tapping anywhere outside the field so it
      // never sits on top of the Buy button.
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: TWScaffoldBackground(
          child: SafeArea(
            top: false,
            child: RefreshIndicator(
              color: TWColors.accent,
              backgroundColor: TWColors.surfaceCard,
              onRefresh: _refresh,
              child: _buildBody(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const TWBusyIndicator(
        title: 'Ranking momentum…',
        subtitle: 'Computing 12-1 momentum across the liquid US universe.',
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(TWSpace.lg),
        children: [
          TWEmptyState(
            title: 'Momentum unavailable',
            body: _error,
            ctaLabel: 'Retry',
            onCta: _refresh,
          ),
        ],
      );
    }
    final p = _picks;
    if (p == null || p.picks.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(TWSpace.lg),
        children: const [
          TWEmptyState(
            title: 'No momentum picks',
            body: 'Not enough cached history to rank names right now.',
          ),
        ],
      );
    }

    // Extra bottom padding equal to the keyboard inset so the Buy button can
    // always be scrolled clear of the number pad.
    final kb = MediaQuery.of(context).viewInsets.bottom;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
          TWSpace.lg, TWSpace.md, TWSpace.lg, TWSpace.xxxl + kb),
      children: [
        _disclaimerCard(p),
        const SizedBox(height: TWSpace.md),
        _regimeChip(p),
        const SizedBox(height: TWSpace.lg),
        Text('Top ${p.picks.length} by 12-1 momentum',
            style: TWType.label.copyWith(color: TWColors.textSecondary)),
        if (_isOwner) ...[
          const SizedBox(height: 2),
          Text('Tap a name to buy it individually · LIVE',
              style: TWType.caption.copyWith(color: TWColors.textTertiary)),
        ],
        const SizedBox(height: TWSpace.sm),
        ...p.picks.map(_pickRow),
        const SizedBox(height: TWSpace.lg),
        Text(
          '${p.tradableSize} tradable names screened · monthly hold · '
          'no tight stop (rebalance is the exit)',
          style: TWType.caption.copyWith(color: TWColors.textTertiary),
        ),
        if (_isOwner) ...[
          const SizedBox(height: TWSpace.xl),
          _ownerBuyPanel(p),
        ],
      ],
    );
  }

  Widget _disclaimerCard(MomentumPicks p) {
    return TWGlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.science_outlined, color: TWColors.warn, size: 20),
          const SizedBox(width: TWSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('EXPERIMENTAL · research signal (Stage-3b)',
                    style: TWType.caption.copyWith(
                        color: TWColors.warn, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  p.disclaimer,
                  style: TWType.caption
                      .copyWith(color: TWColors.textSecondary, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _regimeChip(MomentumPicks p) {
    final stress = p.isStress;
    final color = stress ? TWColors.warn : TWColors.up;
    final label = stress ? 'MARKET STRESS' : 'BULL REGIME';
    return TWGlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(stress ? Icons.warning_amber_rounded : Icons.trending_up,
              color: color, size: 20),
          const SizedBox(width: TWSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TWType.caption
                        .copyWith(color: color, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(p.regimeNote,
                    style: TWType.caption.copyWith(
                        color: TWColors.textSecondary, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickRow(MomentumPick pick) {
    final momPct = pick.momentum * 100;
    final card = TWFloatingCard(
      padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.lg, vertical: TWSpace.md),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('${pick.rank}',
                style: TWType.label.copyWith(color: TWColors.textTertiary)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(pick.symbol, style: TWType.label),
                const SizedBox(height: 2),
                Text('\$${pick.lastPrice.toStringAsFixed(2)}',
                    style: TWType.caption
                        .copyWith(color: TWColors.textTertiary)),
              ],
            ),
          ),
          Text(
            '${momPct >= 0 ? '+' : ''}${momPct.toStringAsFixed(1)}%',
            style: TWType.tabular(TWType.label).copyWith(
                color: momPct >= 0 ? TWColors.up : TWColors.down,
                fontWeight: FontWeight.w700),
          ),
          // Owner-only single-buy affordance: tap the row (or this icon) to
          // buy just this one name on Moomoo LIVE.
          if (_isOwner) ...[
            const SizedBox(width: TWSpace.sm),
            const Icon(Icons.add_shopping_cart,
                size: 18, color: TWColors.accent),
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: TWSpace.sm),
      // Non-owners get a static read-only row; the owner can tap a name to buy
      // that single momentum pick (in addition to the buy-all basket below).
      child: _isOwner
          ? Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(TWRadius.cardLg),
              child: InkWell(
                borderRadius: BorderRadius.circular(TWRadius.cardLg),
                onTap: () {
                  FocusScope.of(context).unfocus();
                  _reviewAndBuyOne(pick);
                },
                child: card,
              ),
            )
          : card,
    );
  }

  /// Owner-only: buy a SINGLE momentum name (the tapped pick) on Moomoo LIVE,
  /// sized by the per-position amount. Mirrors the basket-buy flow (preview ->
  /// confirm -> paced order) but for exactly one symbol. Falls back to a prompt
  /// if the per-position amount hasn't been entered yet.
  Future<void> _reviewAndBuyOne(MomentumPick pick) async {
    final size = _perPosition;
    final token = AuthScope.read(context).token;
    final secret = widget.secretStore.secret;
    if (token == null || secret == null || secret.isEmpty) {
      _snack('LIVE trading unavailable (missing credentials).');
      return;
    }
    if (size == null) {
      _snack('Enter an amount per position first, then tap a name to buy it.');
      return;
    }

    // 1) Preview (single-symbol basket).
    MomentumBasketPreview preview;
    try {
      preview = await widget.repository.momentumBasketPreview(
        symbols: [pick.symbol],
        perPositionUsd: size,
        token: token,
        secret: secret,
      );
    } catch (e) {
      _snack('Preview failed. $e');
      return;
    }
    if (!mounted) return;
    if (preview.legs.isEmpty) {
      _snack('Could not size an order for ${pick.symbol} right now.');
      return;
    }
    final leg = preview.legs.first;

    // 2) Confirm dialog.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TWColors.surfaceCard,
        title: const Text('Confirm LIVE buy', style: TWType.body),
        content: Text(
          'Real money. 1 MARKET BUY of ${leg.quantity.toStringAsFixed(4)} sh '
          '${leg.symbol} (≈ \$${size.toStringAsFixed(0)}).',
          style: TWType.caption
              .copyWith(color: TWColors.textSecondary, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Buy ${leg.symbol}',
                style: const TextStyle(color: TWColors.warn)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 3) Place the single order (same paced/tagged engine as the basket).
    await _runOrders(
      [_MomentumOrder(symbol: leg.symbol, side: 'BUY', quantity: leg.quantity)],
      token: token,
      secret: secret,
    );
  }

  // -- Owner-only real-money basket buy ------------------------------------ #
  Widget _ownerBuyPanel(MomentumPicks p) {
    return TWPremiumCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt, color: TWColors.warn, size: 20),
              const SizedBox(width: TWSpace.sm),
              Text('One-tap basket buy · LIVE', style: TWType.label),
            ],
          ),
          const SizedBox(height: TWSpace.sm),
          Text(
            'Places a real MARKET BUY for each of the ${p.picks.length} names on '
            'Moomoo LIVE, sized by your amount per position. Real money.',
            style: TWType.caption
                .copyWith(color: TWColors.textSecondary, height: 1.35),
          ),
          const SizedBox(height: TWSpace.lg),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _sizeCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  // A visible Done/submit action so the number pad (which has no
                  // return key) can be dismissed without tapping away.
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => FocusScope.of(context).unfocus(),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  style: TWType.body,
                  decoration: const InputDecoration(
                    prefixText: '\$ ',
                    labelText: 'Per position (USD)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          const SizedBox(height: TWSpace.sm),
          if (_perPosition != null)
            Text(
              'Est. total ≈ \$${(_perPosition! * p.picks.length).toStringAsFixed(0)} '
              'across ${p.picks.length} names (per-order cap applies).',
              style: TWType.caption.copyWith(color: TWColors.textTertiary),
            ),
          const SizedBox(height: TWSpace.lg),
          TWGradientButton(
            label: 'Review & Buy Top ${p.picks.length}',
            icon: Icons.shopping_cart_checkout,
            onPressed: _perPosition == null
                ? null
                : () {
                    FocusScope.of(context).unfocus();
                    _reviewAndBuy(p);
                  },
          ),
          const SizedBox(height: TWSpace.sm),
          TWGhostButton(
            label: 'Rebalance to Top ${p.picks.length}',
            icon: Icons.sync,
            onPressed: _perPosition == null
                ? null
                : () {
                    FocusScope.of(context).unfocus();
                    _reviewAndRebalance(p);
                  },
          ),
          const SizedBox(height: TWSpace.xs),
          Text(
            'Sells momentum names that dropped out of the top ${p.picks.length} '
            'and buys the new ones. Only touches positions bought here.',
            style: TWType.caption.copyWith(color: TWColors.textTertiary),
          ),
        ],
      ),
    );
  }

  Future<void> _reviewAndBuy(MomentumPicks p) async {
    final size = _perPosition;
    final token = AuthScope.read(context).token;
    final secret = widget.secretStore.secret;
    if (size == null) return;
    if (token == null || secret == null || secret.isEmpty) {
      _snack('LIVE trading unavailable (missing credentials).');
      return;
    }
    final symbols = p.picks.map((e) => e.symbol).toList();

    // 1) Preview.
    MomentumBasketPreview preview;
    try {
      preview = await widget.repository.momentumBasketPreview(
        symbols: symbols,
        perPositionUsd: size,
        token: token,
        secret: secret,
      );
    } catch (e) {
      _snack('Preview failed. $e');
      return;
    }
    if (!mounted) return;

    // 2) Confirm dialog. Trade unlock is done manually in the OpenD GUI, so no
    //    PIN is collected here (matches the Explore "Buy all" flow).
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TWColors.surfaceCard,
        title: const Text('Confirm LIVE basket buy', style: TWType.body),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Real money. ${preview.legs.length} MARKET BUY orders, '
                '≈ \$${size.toStringAsFixed(0)} each '
                '(≈ \$${preview.totalEstNotional.toStringAsFixed(0)} total).',
                style: TWType.caption
                    .copyWith(color: TWColors.textSecondary, height: 1.35),
              ),
              const SizedBox(height: TWSpace.md),
              ...preview.legs.map((l) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(child: Text(l.symbol, style: TWType.caption)),
                        Text(
                          '${l.quantity.toStringAsFixed(4)} sh',
                          style: TWType.tabular(TWType.caption)
                              .copyWith(color: TWColors.textTertiary),
                        ),
                      ],
                    ),
                  )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Place ${preview.legs.length} orders',
                style: const TextStyle(color: TWColors.warn)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 3) Place. Each leg is its own MARKET BUY, exactly like the Explore
    //    "Buy all" flow, so the owner sees a real per-order progress bar
    //    counting up (1/n, 2/n, …) instead of an indeterminate sweep.
    final orders = [
      for (final l in preview.legs)
        _MomentumOrder(symbol: l.symbol, side: 'BUY', quantity: l.quantity),
    ];
    await _runOrders(orders, token: token, secret: secret);
  }

  /// Compare the momentum-owned holdings against the fresh top-N and, on the
  /// owner's confirmation, SELL the dropouts then BUY the new entries. Only
  /// momentum-owned positions are ever sold; other strategies are untouched.
  Future<void> _reviewAndRebalance(MomentumPicks p) async {
    final size = _perPosition;
    final token = AuthScope.read(context).token;
    final secret = widget.secretStore.secret;
    if (size == null) return;
    if (token == null || secret == null || secret.isEmpty) {
      _snack('LIVE trading unavailable (missing credentials).');
      return;
    }

    // 1) Preview the rebalance plan.
    MomentumRebalancePreview plan;
    try {
      plan = await widget.repository.momentumRebalancePreview(
        perPositionUsd: size,
        topN: p.picks.length,
        token: token,
        secret: secret,
      );
    } catch (e) {
      _snack('Rebalance preview failed. $e');
      return;
    }
    if (!mounted) return;

    if (plan.isEmpty) {
      _snack('Already aligned with the top ${p.picks.length}. Nothing to do.');
      return;
    }

    // 2) Confirm dialog listing the SELLs, BUYs and HOLDs.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TWColors.surfaceCard,
        title: const Text('Confirm LIVE rebalance', style: TWType.body),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Real money. ${plan.sells.length} SELL then '
                '${plan.buys.length} BUY MARKET order(s). '
                '${plan.holds.length} position(s) kept.',
                style: TWType.caption
                    .copyWith(color: TWColors.textSecondary, height: 1.35),
              ),
              if (plan.sells.isNotEmpty) ...[
                const SizedBox(height: TWSpace.md),
                Text('Sell (dropped out)',
                    style: TWType.caption.copyWith(color: TWColors.down)),
                const SizedBox(height: TWSpace.xs),
                ...plan.sells.map((s) => _rebalRow(
                    s.symbol, '${s.quantity.toStringAsFixed(4)} sh')),
              ],
              if (plan.buys.isNotEmpty) ...[
                const SizedBox(height: TWSpace.md),
                Text('Buy (new entries)',
                    style: TWType.caption.copyWith(color: TWColors.up)),
                const SizedBox(height: TWSpace.xs),
                ...plan.buys.map((b) => _rebalRow(
                    b.symbol, '${b.quantity.toStringAsFixed(4)} sh')),
              ],
              if (plan.holds.isNotEmpty) ...[
                const SizedBox(height: TWSpace.md),
                Text('Hold: ${plan.holds.join(', ')}',
                    style: TWType.caption
                        .copyWith(color: TWColors.textTertiary)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
                'Place ${plan.sells.length + plan.buys.length} orders',
                style: const TextStyle(color: TWColors.warn)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 3) Execute: SELL the dropouts first (frees cash), then BUY the new
    //    entries. Single per-order progress bar across the whole plan.
    final orders = <_MomentumOrder>[
      for (final s in plan.sells)
        _MomentumOrder(symbol: s.symbol, side: 'SELL', quantity: s.quantity),
      for (final b in plan.buys)
        _MomentumOrder(symbol: b.symbol, side: 'BUY', quantity: b.quantity),
    ];
    await _runOrders(orders, token: token, secret: secret);
  }

  Widget _rebalRow(String symbol, String qty) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(symbol, style: TWType.caption)),
            Text(qty,
                style: TWType.tabular(TWType.caption)
                    .copyWith(color: TWColors.textTertiary)),
          ],
        ),
      );

  /// Place a list of MARKET orders one at a time, mirroring the Explore
  /// "Buy all" engine: ~2.2s pacing (Moomoo ~15 orders/30s), transient
  /// rate-limit retry, per-stock skip guards, a tap-to-stop cancel, and a
  /// determinate progress bar counting up. Every order is tagged
  /// strategy=momentum so the ledger stays in step for future rebalances.
  Future<void> _runOrders(
    List<_MomentumOrder> orders, {
    required String token,
    required String secret,
  }) async {
    if (orders.isEmpty) return;
    final progress = ValueNotifier<int>(0);
    final cancel = _MomentumCancelToken();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => _MomentumBuyProgressDialog(
        total: orders.length,
        progress: progress,
        cancel: cancel,
      ),
    );

    var filled = 0;
    var skipped = 0;
    var failed = 0;
    final failures = <String>[];
    var cancelled = false;

    // Keep the screen awake for the whole paced run so the OS does not sleep
    // the app mid-basket and abandon orders half-way.
    await KeepAwake.guard(() async {
    for (var i = 0; i < orders.length; i++) {
      if (cancel.isCancelled) {
        cancelled = true;
        break;
      }
      final order = orders[i];

      // Moomoo throttles placement to ~15 orders / 30s. Pace ourselves so a
      // large plan does not trip the broker's rate limiter.
      if (i > 0 && _kMomentumOrderGap > Duration.zero) {
        await Future<void>.delayed(_kMomentumOrderGap);
      }

      var outcome = 0; // 0=filled, 1=skipped, 2=failed
      String? failMsg;
      for (var attempt = 0; attempt < _kMomentumMaxRetries; attempt++) {
        if (cancel.isCancelled) break;
        try {
          await widget.repository.moomooPlace(
            token: token,
            secret: secret,
            symbol: order.symbol,
            side: order.side,
            quantity: order.quantity,
            orderType: 'MARKET',
            strategy: 'momentum',
          );
          outcome = 0;
          break;
        } on ApiException catch (e) {
          final msg = e.message.toLowerCase();
          // Transient broker rate limit: wait out the window and retry.
          if (msg.contains('high frequency') ||
              msg.contains('per 30 seconds') ||
              msg.contains('rate limit') ||
              msg.contains('too many requests')) {
            outcome = 2;
            failMsg = e.message;
            if (attempt < _kMomentumMaxRetries - 1) {
              await Future<void>.delayed(_kMomentumRetryBackoff);
              continue;
            }
            break;
          }
          // Expected, non-fatal per-stock outcomes: skip & continue the run.
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
        failures.add('${order.symbol}: ${failMsg ?? 'failed'}');
      }
      progress.value = i + 1;
    }
    });

    progress.dispose();
    if (!mounted) return;
    // Close the progress dialog only if it is still up (a confirmed cancel may
    // have already popped it).
    if (!cancel.dialogClosed) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    final parts = <String>[
      'Placed $filled order(s)',
      if (skipped > 0) '$skipped skipped',
      if (failed > 0) '$failed failed',
    ];
    _snack('${cancelled ? 'Stopped. ' : ''}${parts.join(', ')}.');
  }

  void _openComparison() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StrategyComparisonPage(
        repository: widget.repository,
        secretStore: widget.secretStore,
      ),
    ));
  }

  void _openHoldings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MomentumHoldingsPage(
        repository: widget.repository,
        secretStore: widget.secretStore,
        topN: _topN,
      ),
    ));
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// Default pacing for the LIVE basket buy: Moomoo allows ~15 orders / 30s, so a
/// ~2.2s gap keeps us comfortably under the limit (≈ 13-14 orders / 30s).
const Duration _kMomentumOrderGap = Duration(milliseconds: 2200);

/// How long to wait after a transient rate-limit rejection before retrying.
const Duration _kMomentumRetryBackoff = Duration(seconds: 8);

/// Max attempts per order (initial try + retries) for transient rate limits.
const int _kMomentumMaxRetries = 3;

/// Cooperative cancel flag shared between the basket-buy loop and its progress
/// dialog so the owner can stop a run in flight.
class _MomentumCancelToken {
  bool isCancelled = false;
  bool dialogClosed = false;
}

/// One MARKET order in a basket buy or rebalance run.
class _MomentumOrder {
  const _MomentumOrder({
    required this.symbol,
    required this.side, // BUY | SELL
    required this.quantity,
  });

  final String symbol;
  final String side;
  final double quantity;
}

/// A modal shown while a LIVE basket buy is being placed. Each leg is placed as
/// its own order, so this shows a real determinate bar counting up (1/n, 2/n,
/// …) — matching the Explore "Buy all" flow. Tap outside to stop.
class _MomentumBuyProgressDialog extends StatefulWidget {
  const _MomentumBuyProgressDialog({
    required this.total,
    required this.progress,
    required this.cancel,
  });

  final int total;
  final ValueNotifier<int> progress;
  final _MomentumCancelToken cancel;

  @override
  State<_MomentumBuyProgressDialog> createState() =>
      _MomentumBuyProgressDialogState();
}

class _MomentumBuyProgressDialogState
    extends State<_MomentumBuyProgressDialog> {
  bool _stopping = false;

  Future<bool> _confirmStop() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TWColors.surfaceCard,
        title: const Text('Stop the purchase?', style: TWType.body),
        content: Text(
          'Orders already placed will stay. The remaining orders won’t '
          'be placed.',
          style: TWType.caption.copyWith(color: TWColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
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
      widget.cancel.dialogClosed = true;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestCancel();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _requestCancel,
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: TWSpace.xxl),
              child: TWFloatingCard(
                padding: const EdgeInsets.all(TWSpace.xl),
                child: ValueListenableBuilder<int>(
                  valueListenable: widget.progress,
                  builder: (context, done, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Placing your orders', style: TWType.body),
                      const SizedBox(height: TWSpace.xs),
                      Text(
                        _stopping
                            ? 'Stopping…  $done / ${widget.total}'
                            : 'Placing LIVE orders…  $done / ${widget.total}',
                        style: TWType.caption.copyWith(
                          color: TWColors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: TWSpace.lg),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: widget.total == 0 ? null : done / widget.total,
                          minHeight: 8,
                          backgroundColor:
                              TWColors.bgBase.withValues(alpha: 0.6),
                          color: TWColors.accent,
                        ),
                      ),
                      const SizedBox(height: TWSpace.sm),
                      Text(
                        'Tap outside to stop.',
                        style: TWType.caption
                            .copyWith(color: TWColors.textTertiary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
