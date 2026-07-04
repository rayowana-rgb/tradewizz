import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/momentum.dart';
import '../repositories/stock_repository.dart';
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

    // 2) Confirm dialog with an optional trade PIN.
    final pinCtrl = TextEditingController();
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
              const SizedBox(height: TWSpace.md),
              TextField(
                controller: pinCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                style: TWType.body,
                decoration: const InputDecoration(
                  labelText: 'Trade PIN (if set)',
                ),
              ),
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
    final pin = pinCtrl.text.trim();
    pinCtrl.dispose();
    if (confirmed != true || !mounted) return;

    // 3) Place. Show a left->right progress bar so the owner can see the buy is
    //    running until it finishes. The backend places all legs in one call, so
    //    this is an indeterminate sweep (not per-leg), dismissed on completion.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => _BuyProgressDialog(orderCount: preview.legs.length),
    );

    MomentumBasketResult result;
    try {
      result = await widget.repository.momentumBasketBuy(
        symbols: symbols,
        perPositionUsd: size,
        token: token,
        secret: secret,
        confirm: true,
        tradePin: pin.isEmpty ? null : pin,
      );
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop(); // close bar
      _snack('Order placement failed. $e');
      return;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close the progress bar
    _snack('Placed ${result.placed} order(s)'
        '${result.failed > 0 ? ', ${result.failed} failed' : ''}.');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// A modal shown while a LIVE basket buy is being placed. Displays an animated
/// left->right progress sweep so the owner can clearly see the purchase is
/// running until it completes. The backend places every leg in a single call,
/// so this is an indeterminate (looping) sweep rather than per-leg progress.
class _BuyProgressDialog extends StatefulWidget {
  const _BuyProgressDialog({required this.orderCount});

  final int orderCount;

  @override
  State<_BuyProgressDialog> createState() => _BuyProgressDialogState();
}

class _BuyProgressDialogState extends State<_BuyProgressDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: TWSpace.xxl),
        child: TWFloatingCard(
          padding: const EdgeInsets.all(TWSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Placing your orders', style: TWType.body),
              const SizedBox(height: TWSpace.xs),
              Text(
                'Sending ${widget.orderCount} MARKET BUY '
                'order${widget.orderCount == 1 ? '' : 's'} to Moomoo LIVE. '
                'Please keep the app open.',
                style: TWType.caption.copyWith(
                  color: TWColors.textSecondary,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: TWSpace.lg),
              // The left->right sweeping bar.
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: SizedBox(
                  height: 8,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      const barFraction = 0.42; // width of the moving segment
                      final barW = w * barFraction;
                      return Stack(
                        children: [
                          // Track.
                          Container(
                            color: TWColors.bgBase.withValues(alpha: 0.6),
                          ),
                          // Moving segment, driven left->right by the controller.
                          AnimatedBuilder(
                            animation: _c,
                            builder: (context, _) {
                              final travel = w + barW;
                              final x = _c.value * travel - barW;
                              return Transform.translate(
                                offset: Offset(x, 0),
                                child: Container(
                                  width: barW,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0x004F7CFF),
                                        TWColors.accent,
                                        Color(0x004F7CFF),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
