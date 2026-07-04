import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/momentum.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart' show ApiException;
import '../services/auth_scope.dart';
import '../services/moomoo_secret_store.dart';
import '../theme_tradewizz.dart';
import '../widgets/ds/ds.dart';
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
    return Padding(
      padding: const EdgeInsets.only(bottom: TWSpace.sm),
      child: TWFloatingCard(
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
          ],
        ),
      ),
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

    // 3) Place. Place each leg as its own MARKET BUY sequentially, exactly like
    //    the Explore "Buy all" flow, so the owner sees a real per-order progress
    //    bar counting up (1/n, 2/n, …) instead of an indeterminate sweep.
    //    (Trade unlock is done manually in the OpenD GUI, so no PIN is sent.)
    final progress = ValueNotifier<int>(0);
    final cancel = _MomentumCancelToken();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => _MomentumBuyProgressDialog(
        total: preview.legs.length,
        progress: progress,
        cancel: cancel,
      ),
    );

    var filled = 0;
    var skipped = 0;
    var failed = 0;
    final failures = <String>[];
    var cancelled = false;

    for (var i = 0; i < preview.legs.length; i++) {
      if (cancel.isCancelled) {
        cancelled = true;
        break;
      }
      final leg = preview.legs[i];

      // Moomoo throttles placement to ~15 orders / 30s. Pace ourselves so a
      // large basket does not trip the broker's rate limiter.
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
            symbol: leg.symbol,
            side: 'BUY',
            quantity: leg.quantity,
            orderType: 'MARKET',
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
        failures.add('${leg.symbol}: ${failMsg ?? 'failed'}');
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
    final parts = <String>[
      'Placed $filled order(s)',
      if (skipped > 0) '$skipped skipped',
      if (failed > 0) '$failed failed',
    ];
    _snack('${cancelled ? 'Stopped. ' : ''}${parts.join(', ')}.');
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
