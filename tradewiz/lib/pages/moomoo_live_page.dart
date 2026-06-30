import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/moomoo_live.dart';
import '../models/phase3.dart';
import '../models/subscription.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/moomoo_secret_store.dart';
import '../theme_tradewizz.dart';
import '../widgets/ds/tw_scaffold_background.dart';

/// PRIVATE owner-only LIVE trading screen, backed by the Moomoo bridge
/// (/v1/broker/moomoo/*). REAL MONEY. This is intentionally gated:
///   * only the owner uid sees the entry point (see [kMoomooOwnerUid]);
///   * a per-device secret must be set before anything works;
///   * placement always shows a LIVE confirmation step.
///
/// The Moomoo OpenD gateway must be running and UNLOCKED on the host Mac for
/// orders to go through; otherwise the backend surfaces a clear error.
const int kMoomooOwnerUid = 2;

// Live bulk pacing for the "Trim" (take-profit-all) flow. Moomoo throttles
// placement to ~15 orders / 30s, so we space orders out and retry a transient
// rate-limit hit instead of dropping it. Mirrors the screener "Buy all" pacing.
const Duration _kTrimOrderGap = Duration(milliseconds: 2200);
const Duration _kTrimRetryBackoff = Duration(seconds: 8);
const int _kTrimMaxRetries = 3;

class MoomooLivePage extends StatefulWidget {
  const MoomooLivePage({
    super.key,
    required this.repository,
    required this.secretStore,
    this.liveBulkOrderGap,
  });

  final StockRepository repository;
  final MoomooSecretStore secretStore;

  /// Test seam: pacing between live bulk "Trim" orders. Inject [Duration.zero]
  /// in widget tests so the take-profit-all flow runs instantly without the
  /// real broker rate-limit backoff. Production uses [_kTrimOrderGap].
  final Duration? liveBulkOrderGap;

  @override
  State<MoomooLivePage> createState() => _MoomooLivePageState();
}

class _MoomooLivePageState extends State<MoomooLivePage> {
  bool _loading = false;
  String? _error;
  MoomooLiveAccount? _account;
  List<MoomooLivePosition> _positions = const [];
  MoomooLiveManagerReport? _manager;
  PortfolioHealth? _health;
  RebalanceReport? _rebalance;
  List<MoomooLiveEquityPoint> _equity = const [];
  // Still-working (pending / partially filled) orders, keyed for quick lookup
  // by symbol so Rebalancing AI rows can flag a position that already has an
  // order in flight (e.g. submitted while the market was closed).
  List<MoomooLiveOpenOrder> _openOrders = const [];
  // Server-managed stop-loss / take-profit brackets, keyed by symbol so each
  // position tile can show its active bracket (or offer to attach one).
  List<MoomooLiveBracket> _brackets = const [];
  // Guards the "Protect all" batch toggle so it can't run twice concurrently.
  bool _protectAllBusy = false;
  // When true, Rebalancing AI rows that already have a pending order in flight
  // are hidden so they don't keep nagging after execution. Persisted.
  static const String _kHidePendingRebPref =
      'tradewizz.moomoo.hidePendingReb';
  bool _hidePendingReb = false;

  /// Whether the positions list is collapsed. Persisted across launches via
  /// SharedPreferences (key [_kHidePositionsPref]).
  static const String _kHidePositionsPref = 'tradewizz.moomoo.hidePositions';
  static const String _kHideManagerPref = 'tradewizz.moomoo.hideManager';
  static const String _kHideHealthPref = 'tradewizz.moomoo.hideHealth';
  static const String _kHideRebalancePref = 'tradewizz.moomoo.hideRebalance';
  // Sort order for the Positions list. Persisted so the user's preferred view
  // survives relaunches. 'default' keeps the broker's order.
  static const String _kPosSortPref = 'tradewizz.moomoo.posSort';
  bool _hidePositions = false;
  bool _hideManager = false;
  bool _hideHealth = false;
  bool _hideRebalance = false;
  // One of: 'default' | 'pl' | 'weight'. High-to-low for pl/weight.
  String _posSort = 'default';
  // Symbol whose inline SELL slider is currently expanded in the Positions
  // list (null = none). Tapping Sell on a tile toggles its slider open/closed.
  // Only one of [_sellExpanded] / [_buyExpanded] can be open at a time.
  String? _sellExpanded;

  // Symbol whose inline BUY slider is currently expanded in the Positions list
  // (null = none). Tapping Buy on a tile toggles its slider open/closed.
  String? _buyExpanded;

  // Same per-side expand state, but for the Rebalancing AI action rows. Only
  // one of these (across both lists) is conceptually open per symbol; the
  // rebalance rows keep their own keys so they don't clash with Positions.
  String? _rebSellExpanded;
  String? _rebBuyExpanded;

  // Profit threshold for the "Trim" take-profit-all flow. The user picks a
  // mode (percent of cost or absolute dollars) and a value; a position
  // qualifies when its unrealized P/L in that unit is strictly greater than
  // the value. Both the mode and the per-mode value are persisted so the
  // user's preferred setting survives relaunches.
  static const String _kTrimThresholdPref = 'tradewizz.moomoo.trimThreshold';
  static const String _kTrimDollarPref = 'tradewizz.moomoo.trimDollar';
  static const String _kTrimModePref = 'tradewizz.moomoo.trimMode';
  // Percent threshold (P/L %). 0.0 means "any position in profit".
  double _trimThreshold = 0.0;
  // Dollar threshold (absolute P/L $).
  double _trimDollar = 0.0;
  // 'pct' | 'usd'.
  String _trimMode = 'pct';

  // User-configurable SL/TP percentages used by both the per-position Protect
  // action and the Protect-all toggle. Persisted so the trader's plan survives
  // relaunches. _stopPct is stored as a NEGATIVE percent (e.g. -1.0 = -1%),
  // _targetPct as a POSITIVE percent (e.g. 3.0 = +3%). Defaults keep the
  // original -1% / +3% behaviour.
  static const String _kStopPctPref = 'tradewizz.moomoo.sltpStopPct';
  static const String _kTargetPctPref = 'tradewizz.moomoo.sltpTargetPct';
  double _stopPct = -1.0;
  double _targetPct = 3.0;

  Duration get _trimOrderGap => widget.liveBulkOrderGap ?? _kTrimOrderGap;

  String? get _token => AuthScope.read(context).token;

  /// Open positions that are in profit above the given threshold (in the given
  /// mode) and have sellable shares. plRatio is a fraction (0.05 = 5%); plVal
  /// is the absolute unrealized P/L in account currency.
  List<MoomooLivePosition> _trimCandidates(String mode, double value) =>
      _positions.where((p) {
        if (p.canSellQty <= 0) return false;
        final metric = mode == 'usd' ? p.plVal : p.plRatio * 100.0;
        return metric > value;
      }).toList();

  @override
  void initState() {
    super.initState();
    _loadHidePref();
    widget.secretStore.load().then((_) {
      if (mounted && widget.secretStore.hasSecret) _refresh();
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadHidePref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _hidePositions = prefs.getBool(_kHidePositionsPref) ?? false;
      _hideManager = prefs.getBool(_kHideManagerPref) ?? false;
      _hideHealth = prefs.getBool(_kHideHealthPref) ?? false;
      _hideRebalance = prefs.getBool(_kHideRebalancePref) ?? false;
      _hidePendingReb = prefs.getBool(_kHidePendingRebPref) ?? false;
      _posSort = prefs.getString(_kPosSortPref) ?? 'default';
      _trimThreshold = prefs.getDouble(_kTrimThresholdPref) ?? 0.0;
      _trimDollar = prefs.getDouble(_kTrimDollarPref) ?? 0.0;
      _trimMode = prefs.getString(_kTrimModePref) ?? 'pct';
      _stopPct = prefs.getDouble(_kStopPctPref) ?? -1.0;
      _targetPct = prefs.getDouble(_kTargetPctPref) ?? 3.0;
    });
  }

  // Short "-1% / +3%" style label for the current plan, reused in UI/dialogs.
  String get _sltpLabel =>
      '${_stopPct.toStringAsFixed(_stopPct % 1 == 0 ? 0 : 2)}%'
      ' / +${_targetPct.toStringAsFixed(_targetPct % 1 == 0 ? 0 : 2)}%';

  /// Edit + persist the SL/TP percentages used for all Protect actions.
  Future<void> _editSltpSettings() async {
    final stopCtl = TextEditingController(
        text: _stopPct.abs().toStringAsFixed(_stopPct % 1 == 0 ? 0 : 2));
    final targetCtl = TextEditingController(
        text: _targetPct.toStringAsFixed(_targetPct % 1 == 0 ? 0 : 2));
    final formKey = GlobalKey<FormState>();

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TWColors.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(TWRadius.cardLg)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: TWSpace.lg,
          right: TWSpace.lg,
          top: TWSpace.lg,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + TWSpace.lg,
        ),
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Protect settings', style: TWType.label),
              const SizedBox(height: TWSpace.xs),
              Text(
                'Used for both Protect and Protect all. Stop-loss sells below '
                'entry; take-profit sells above. Tip: with a flat ~\$0.99/order '
                'fee, TP +3.2% on SL -1% gives roughly a 2:1 reward:risk.',
                style:
                    TWType.caption.copyWith(color: TWColors.textTertiary),
              ),
              const SizedBox(height: TWSpace.md),
              TextFormField(
                key: const Key('moomoo_sltp_stop_field'),
                controller: stopCtl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: TWType.body,
                decoration: const InputDecoration(
                  labelText: 'Stop-loss below entry (%)',
                  prefixText: '- ',
                  helperText: 'How far price can drop before selling.',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final d = double.tryParse(
                      (v ?? '').trim().replaceAll(',', '.'));
                  if (d == null || d <= 0) return 'Enter a positive %';
                  if (d >= 100) return 'Too large';
                  return null;
                },
              ),
              const SizedBox(height: TWSpace.md),
              TextFormField(
                key: const Key('moomoo_sltp_target_field'),
                controller: targetCtl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: TWType.body,
                decoration: const InputDecoration(
                  labelText: 'Take-profit above entry (%)',
                  prefixText: '+ ',
                  helperText: 'How far price rises before taking profit.',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final d = double.tryParse(
                      (v ?? '').trim().replaceAll(',', '.'));
                  if (d == null || d <= 0) return 'Enter a positive %';
                  if (d >= 1000) return 'Too large';
                  return null;
                },
              ),
              const SizedBox(height: TWSpace.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('moomoo_sltp_settings_save'),
                  style: FilledButton.styleFrom(
                    backgroundColor: TWColors.accent,
                    padding:
                        const EdgeInsets.symmetric(vertical: TWSpace.md),
                  ),
                  onPressed: () {
                    if (!formKey.currentState!.validate()) return;
                    Navigator.pop(ctx, true);
                  },
                  child: const Text('Save plan', style: TWType.label),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (saved != true || !mounted) return;
    final stop = -double.parse(stopCtl.text.trim().replaceAll(',', '.'));
    final target = double.parse(targetCtl.text.trim().replaceAll(',', '.'));
    setState(() {
      _stopPct = stop;
      _targetPct = target;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kStopPctPref, stop);
    await prefs.setDouble(_kTargetPctPref, target);
    _toast('Protect plan saved: $_sltpLabel');
  }

  /// Cycle / set the positions sort. Tapping an active chip toggles it back to
  /// the broker's default order; tapping an inactive chip selects it.
  Future<void> _setPosSort(String mode) async {
    final next = (_posSort == mode) ? 'default' : mode;
    setState(() => _posSort = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPosSortPref, next);
  }

  Future<void> _toggleHidePositions() async {
    final next = !_hidePositions;
    setState(() => _hidePositions = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHidePositionsPref, next);
  }

  Future<void> _toggleHide(
    String key,
    bool current,
    void Function(bool) set,
  ) async {
    final next = !current;
    setState(() => set(next));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, next);
  }

  Future<void> _refresh() async {
    final token = _token;
    final secret = widget.secretStore.secret;
    if (token == null || secret == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final acct = await widget.repository.moomooAccount(
        token: token,
        secret: secret,
      );
      final pos = await widget.repository.moomooPositions(
        token: token,
        secret: secret,
      );
      if (!mounted) return;
      setState(() {
        _account = acct;
        // Hide fully sold-out holdings (quantity 0): the broker can still
        // report them transiently, but they are not open positions.
        _positions = pos.where((p) => p.quantity > 0).toList();
        _loading = false;
      });
      // Advisory analytics (Manager / Health / Rebalance) are fetched without
      // blocking; a failure must never clear the account / positions view.
      try {
        final mgr = await widget.repository.moomooManager(
          token: token,
          secret: secret,
        );
        if (mounted) setState(() => _manager = mgr);
      } catch (_) {
        /* keep account + positions */
      }
      try {
        final h = await widget.repository.moomooHealth(
          token: token,
          secret: secret,
        );
        if (mounted) setState(() => _health = h);
      } catch (_) {
        /* keep account + positions */
      }
      try {
        final rb = await widget.repository.moomooRebalance(
          token: token,
          secret: secret,
        );
        if (mounted) setState(() => _rebalance = rb);
      } catch (_) {
        /* keep account + positions */
      }
      try {
        final orders = await widget.repository.moomooOpenOrders(
          token: token,
          secret: secret,
        );
        if (mounted) setState(() => _openOrders = orders);
      } catch (_) {
        /* keep account + positions; pending flags simply won't show */
      }
      try {
        // Force an immediate monitor evaluation on load so any level touched
        // while the app was closed is acted on now, then show the result.
        final br = await widget.repository.moomooCheckBrackets(
          token: token,
          secret: secret,
        );
        if (mounted) setState(() => _brackets = br);
      } catch (_) {
        /* SL/TP overlay is best-effort */
      }
      try {
        final eq = await widget.repository.moomooAccountHistory(
          token: token,
          secret: secret,
        );
        if (mounted) setState(() => _equity = eq);
      } catch (_) {
        /* growth chart is best-effort */
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load live account.';
        _loading = false;
      });
    }
  }

  Future<void> _editSecret() async {
    final controller = TextEditingController(
      text: widget.secretStore.secret ?? '',
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TWColors.surfaceCard,
        title: const Text('Live trading secret', style: TWType.title3),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the private Moomoo bridge secret. It is stored securely '
              'on this device only and never embedded in the app.',
              style: TWType.caption,
            ),
            const SizedBox(height: TWSpace.md),
            TextField(
              key: const Key('moomoo_secret_field'),
              controller: controller,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              style: TWType.body,
              decoration: const InputDecoration(
                hintText: 'X-Moomoo-Secret',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          if (widget.secretStore.hasSecret)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('__clear__'),
              child: const Text(
                'Clear',
                style: TextStyle(color: TWColors.down),
              ),
            ),
          FilledButton(
            key: const Key('moomoo_secret_save'),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (result == '__clear__') {
      await widget.secretStore.clear();
      if (mounted) {
        setState(() {
          _account = null;
          _positions = const [];
          _openOrders = const [];
          _brackets = const [];
          _error = null;
        });
      }
      return;
    }
    await widget.secretStore.setSecret(result);
    if (mounted) {
      setState(() {});
      if (widget.secretStore.hasSecret) _refresh();
    }
  }

  Future<void> _openTicket([
    String? prefillSymbol,
    String? prefillSide,
    double? prefillQty,
  ]) async {
    final token = _token;
    final secret = widget.secretStore.secret;
    if (token == null || secret == null) return;
    final placed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MoomooOrderTicketPage(
          repository: widget.repository,
          token: token,
          secret: secret,
          prefillSymbol: prefillSymbol,
          prefillSide: prefillSide,
          prefillQty: prefillQty,
        ),
      ),
    );
    if (placed == true && mounted) _refresh();
  }

  Future<void> _setTrim(String mode, double value) async {
    setState(() {
      _trimMode = mode;
      if (mode == 'usd') {
        _trimDollar = value;
      } else {
        _trimThreshold = value;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTrimModePref, mode);
    if (mode == 'usd') {
      await prefs.setDouble(_kTrimDollarPref, value);
    } else {
      await prefs.setDouble(_kTrimThresholdPref, value);
    }
  }

  // Format a profit-threshold value for display in the active mode.
  String _trimLabel(String mode, double value, String currency) =>
      mode == 'usd'
          ? _money(value, currency)
          : '${value.toStringAsFixed(1)}%';

  // Per-position metric text in the active mode (always a gain here).
  String _trimMetric(String mode, MoomooLivePosition p, String currency) =>
      mode == 'usd'
          ? '+${_money(p.plVal, currency)}'
          : '+${(p.plRatio * 100).toStringAsFixed(1)}%';

  /// Bottom sheet: pick a profit threshold (percent OR dollars), preview which
  /// winners qualify, then take profit on ALL of them in one go (full sellable
  /// qty, MARKET).
  Future<void> _openTrimSheet() async {
    if (!widget.secretStore.hasSecret) return;
    final currency = _account?.currency ?? 'USD';
    var mode = _trimMode;
    var pctVal = _trimThreshold;
    var usdVal = _trimDollar;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TWColors.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(TWRadius.cardLg)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final value = mode == 'usd' ? usdVal : pctVal;
            final candidates = _trimCandidates(mode, value);
            final winners = _positions.where((p) => p.plVal > 0).length;
            // Slider bounds: 0-50% for percent; 0 to the biggest single gain
            // (rounded up, min $50) for dollars so every winner is reachable.
            final maxGain = _positions.fold<double>(
                0, (m, p) => p.plVal > m ? p.plVal : m);
            final usdMax = (maxGain <= 0 ? 50.0 : (maxGain.ceilToDouble()))
                .clamp(10.0, 100000.0);
            final sliderMax = mode == 'usd' ? usdMax : 50.0;
            return Padding(
              padding: EdgeInsets.only(
                left: TWSpace.lg,
                right: TWSpace.lg,
                top: TWSpace.lg,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + TWSpace.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.content_cut,
                          size: 18, color: TWColors.up),
                      const SizedBox(width: TWSpace.sm),
                      const Expanded(
                        child: Text('Take profit', style: TWType.body),
                      ),
                      // Percent / dollar mode toggle.
                      _TrimModeToggle(
                        mode: mode,
                        currency: currency,
                        onChanged: (m) => setSheet(() => mode = m),
                      ),
                    ],
                  ),
                  const SizedBox(height: TWSpace.xs),
                  Text(
                    'Sell every position whose unrealized profit is above the '
                    'threshold. $winners of ${_positions.length} are in profit.',
                    style: TWType.caption.copyWith(
                        color: TWColors.textSecondary),
                  ),
                  const SizedBox(height: TWSpace.lg),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Profit greater than',
                          style: TWType.label,
                        ),
                      ),
                      Text(
                        _trimLabel(mode, value, currency),
                        key: const Key('moomoo_trim_threshold_label'),
                        style: TWType.body.copyWith(color: TWColors.up),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      trackHeight: 4,
                      activeTrackColor: TWColors.up,
                      inactiveTrackColor: TWColors.hairlineTop,
                      thumbColor: TWColors.up,
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
                    ),
                    child: Slider(
                      key: const Key('moomoo_trim_slider'),
                      value: value.clamp(0.0, sliderMax),
                      max: sliderMax,
                      divisions: 100,
                      label: _trimLabel(mode, value, currency),
                      onChanged: (v) {
                        setSheet(() {
                          if (mode == 'usd') {
                            usdVal = v;
                          } else {
                            pctVal = v;
                          }
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: TWSpace.sm),
                  if (candidates.isEmpty)
                    Text(
                      'No positions are above this threshold.',
                      key: const Key('moomoo_trim_empty'),
                      style: TWType.caption
                          .copyWith(color: TWColors.textTertiary),
                    )
                  else ...[
                    // Total unrealized profit captured if every qualifying
                    // position is sold now (sum of each winner's P/L value).
                    Builder(builder: (_) {
                      final totalGain = candidates.fold<double>(
                          0, (s, p) => s + p.plVal);
                      return Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Will sell ${candidates.length}:',
                              style: TWType.caption.copyWith(
                                  color: TWColors.textSecondary),
                            ),
                          ),
                          Text(
                            'Total profit +${_money(totalGain, currency)}',
                            key: const Key('moomoo_trim_total_gain'),
                            style: TWType.caption.copyWith(
                                color: TWColors.up),
                          ),
                        ],
                      );
                    }),
                    const SizedBox(height: TWSpace.xs),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final p in candidates)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 2),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${p.symbol}  ${_qty(p.canSellQty)} sh',
                                        style: TWType.caption,
                                      ),
                                    ),
                                    Text(
                                      _trimMetric(mode, p, currency),
                                      style: TWType.caption
                                          .copyWith(color: TWColors.up),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: TWSpace.lg),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const Key('moomoo_trim_execute'),
                      style: FilledButton.styleFrom(
                        backgroundColor: TWColors.up,
                        padding: const EdgeInsets.symmetric(
                            vertical: TWSpace.md),
                      ),
                      onPressed: candidates.isEmpty
                          ? null
                          : () async {
                              final nav = Navigator.of(sheetCtx);
                              final chosenMode = mode;
                              final chosenVal =
                                  chosenMode == 'usd' ? usdVal : pctVal;
                              await _setTrim(chosenMode, chosenVal);
                              nav.pop();
                              await _confirmAndRunTrim(
                                  chosenMode, chosenVal, currency);
                            },
                      child: Text(
                        candidates.isEmpty
                            ? 'Nothing to take profit'
                            : 'Take profit on ${candidates.length} · LIVE',
                        style: TWType.label,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// LIVE confirmation gate before placing real sell orders, then run.
  Future<void> _confirmAndRunTrim(
      String mode, double value, String currency) async {
    final candidates = _trimCandidates(mode, value);
    if (candidates.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TWColors.surfaceCard,
        title: const Text('Confirm take profit', style: TWType.body),
        content: Text(
          'This places REAL market SELL orders for '
          '${candidates.length} position(s) with profit above '
          '${_trimLabel(mode, value, currency)}. Real money.',
          style: TWType.caption.copyWith(color: TWColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TWType.label),
          ),
          FilledButton(
            key: const Key('moomoo_trim_confirm'),
            style: FilledButton.styleFrom(backgroundColor: TWColors.up),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sell now', style: TWType.label),
          ),
        ],
      ),
    );
    if (ok == true) await _runTrim(mode, value);
  }

  /// Execute the take-profit-all: a throttled, retried MARKET SELL of the full
  /// sellable quantity for each qualifying position. Mirrors the screener
  /// "Buy all" pacing so we don't trip Moomoo's ~15 orders / 30s rate limit.
  Future<void> _runTrim(String mode, double value) async {
    final token = _token;
    final secret = widget.secretStore.secret;
    if (token == null || secret == null) return;
    final candidates = _trimCandidates(mode, value);
    if (candidates.isEmpty) return;

    var sold = 0;
    var failed = 0;
    final failures = <String>[];
    final gap = _trimOrderGap;

    for (var i = 0; i < candidates.length; i++) {
      final p = candidates[i];
      if (i > 0 && gap > Duration.zero) {
        await Future<void>.delayed(gap);
      }
      var ok = false;
      String? failMsg;
      for (var attempt = 0; attempt < _kTrimMaxRetries; attempt++) {
        try {
          await widget.repository.moomooPlace(
            token: token,
            secret: secret,
            symbol: p.symbol,
            side: 'SELL',
            quantity: p.canSellQty,
            orderType: 'MARKET',
          );
          ok = true;
          break;
        } on ApiException catch (e) {
          final msg = e.message.toLowerCase();
          // Transient broker rate limit: wait the window out and retry.
          if (msg.contains('high frequency') ||
              msg.contains('per 30 seconds') ||
              msg.contains('rate limit') ||
              msg.contains('too many requests')) {
            failMsg = e.message;
            if (attempt < _kTrimMaxRetries - 1) {
              if (gap > Duration.zero) {
                await Future<void>.delayed(_kTrimRetryBackoff);
              }
              continue;
            }
            break;
          }
          failMsg = e.message;
          break;
        } catch (e) {
          failMsg = '$e';
          break;
        }
      }
      if (ok) {
        sold++;
      } else {
        failed++;
        failures.add('${p.symbol}: ${failMsg ?? 'failed'}');
      }
    }

    if (!mounted) return;
    final msg = failed == 0
        ? 'Took profit on $sold position(s).'
        : 'Sold $sold, $failed failed: ${failures.join('; ')}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg, key: const Key('moomoo_trim_result'))),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final hasSecret = widget.secretStore.hasSecret;
    return TWScaffoldBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Moomoo · Live', style: TWType.title2),
          actions: [
            IconButton(
              key: const Key('moomoo_secret_button'),
              icon: const Icon(Icons.vpn_key_outlined),
              tooltip: 'Live trading secret',
              onPressed: _editSecret,
            ),
          ],
        ),
        floatingActionButton: hasSecret
            ? FloatingActionButton.extended(
                key: const Key('moomoo_new_order'),
                backgroundColor: TWColors.accent,
                icon: const Icon(Icons.bolt),
                label: const Text('New order'),
                onPressed: () => _openTicket(),
              )
            : null,
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              TWSpace.lg,
              TWSpace.lg,
              TWSpace.lg,
              TWSpace.xxxxl,
            ),
            children: [
              _liveBanner(),
              const SizedBox(height: TWSpace.lg),
              if (!hasSecret)
                _setupCard()
              else ...[
                if (_error != null) _errorCard(_error!),
                _accountCard(),
                if (_equity.length >= 2) ...[
                  const SizedBox(height: TWSpace.lg),
                  _growthCard(_equity),
                ],
                if (_manager != null) ...[
                  const SizedBox(height: TWSpace.lg),
                  _managerSection(_manager!),
                ],
                if (_health != null) ...[
                  const SizedBox(height: TWSpace.lg),
                  _healthSection(_health!),
                ],
                if (_rebalance != null) ...[
                  const SizedBox(height: TWSpace.lg),
                  _rebalanceSection(_rebalance!),
                ],
                const SizedBox(height: TWSpace.lg),
                _positionsSection(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _liveBanner() {
    return Container(
      padding: const EdgeInsets.all(TWSpace.md),
      decoration: BoxDecoration(
        color: TWColors.down.withValues(alpha: 0.12),
        borderRadius: TWRadius.rCard,
        border: Border.all(color: TWColors.down.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: TWColors.down,
            size: 20,
          ),
          const SizedBox(width: TWSpace.sm),
          Expanded(
            child: Text(
              'LIVE trading — real money. Orders route to your Moomoo account. '
              'OpenD must be running and unlocked.',
              style: TWType.caption.copyWith(color: TWColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _setupCard() {
    return _card(
      key: const Key('moomoo_setup_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Set up live trading', style: TWType.title3),
          const SizedBox(height: TWSpace.sm),
          Text(
            'Enter the private bridge secret to connect this device to your '
            'Moomoo account. It never leaves this device and is not embedded '
            'in the app.',
            style: TWType.caption,
          ),
          const SizedBox(height: TWSpace.md),
          FilledButton.icon(
            key: const Key('moomoo_setup_button'),
            style: FilledButton.styleFrom(backgroundColor: TWColors.accent),
            icon: const Icon(Icons.vpn_key_outlined),
            label: const Text('Enter secret'),
            onPressed: _editSecret,
          ),
        ],
      ),
    );
  }

  Widget _errorCard(String message) {
    return Padding(
      padding: const EdgeInsets.only(bottom: TWSpace.lg),
      child: _card(
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: TWColors.down, size: 20),
            const SizedBox(width: TWSpace.sm),
            Expanded(child: Text(message, style: TWType.caption)),
          ],
        ),
      ),
    );
  }

  Color _riskColor(String level) {
    switch (level.toUpperCase()) {
      case 'LOW':
        return TWColors.up;
      case 'HIGH':
        return TWColors.down;
      default:
        return TWColors.warn;
    }
  }

  Color _sevColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'critical':
        return TWColors.down;
      case 'warning':
        return TWColors.warn;
      default:
        return TWColors.info;
    }
  }

  IconData _sevIcon(String kind) {
    switch (kind) {
      case 'concentration':
        return Icons.pie_chart_outline;
      case 'cash_allocation':
        return Icons.account_balance_wallet_outlined;
      case 'diversification':
        return Icons.scatter_plot_outlined;
      case 'weak_position':
        return Icons.trending_down;
      default:
        return Icons.lightbulb_outline;
    }
  }

  Widget _scoreChip(String label, double value) {
    return Column(
      children: [
        Text(
          value.toStringAsFixed(0),
          style: TWType.body.copyWith(color: TWColors.textPrimary),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TWType.overline.copyWith(color: TWColors.textTertiary),
        ),
      ],
    );
  }

  // A small Show/Hide toggle chip reused by the collapsible analytics cards.
  Widget _toggleChip(Key key, bool hidden, VoidCallback onTap) {
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(TWRadius.chip),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.sm,
          vertical: TWSpace.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hidden
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 16,
              color: TWColors.textTertiary,
            ),
            const SizedBox(width: TWSpace.xs),
            Text(
              hidden ? 'Show' : 'Hide',
              style: TWType.overline.copyWith(color: TWColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Color _healthColor(double score) {
    if (score >= 75) return TWColors.up;
    if (score >= 50) return TWColors.warn;
    return TWColors.down;
  }

  // Flat section (no card box): Stockbits-style header + hairline rows,
  // matching Home. Replaces the boxed Health score card.
  Widget _healthSection(PortfolioHealth h) {
    final c = _healthColor(h.healthScore);
    return Column(
      key: const Key('moomoo_health_card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, thickness: 1, color: TWColors.hairlineTop),
        const SizedBox(height: TWSpace.md),
        Row(
          children: [
            const Expanded(child: Text('Health score', style: TWType.body)),
            Text(
              h.healthScore.toStringAsFixed(0),
              style: TWType.title3.copyWith(color: c),
            ),
            const SizedBox(width: TWSpace.xs),
            Text(
              '/100',
              style: TWType.caption.copyWith(color: TWColors.textTertiary),
            ),
            if (h.exitWarnings.isNotEmpty ||
                h.warnings.isNotEmpty ||
                h.strengths.isNotEmpty)
              _toggleChip(
                const Key('moomoo_toggle_health'),
                _hideHealth,
                () => _toggleHide(
                  _kHideHealthPref,
                  _hideHealth,
                  (v) => _hideHealth = v,
                ),
              ),
          ],
        ),
        if (h.rating.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(h.rating, style: TWType.caption.copyWith(color: c)),
          ),
        const SizedBox(height: TWSpace.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _scoreChip('Diversif.', h.components.diversification),
            _scoreChip('Concentr.', h.components.concentrationRisk),
            _scoreChip('Liquidity', h.components.liquidity),
            _scoreChip('Quality', h.components.quality),
          ],
        ),
        if (!_hideHealth) ...[
          for (final w in h.exitWarnings) _healthLine(w, TWColors.down),
          for (final w in h.warnings) _healthLine(w, TWColors.warn),
          for (final s in h.strengths) _healthLine(s, TWColors.up),
        ],
      ],
    );
  }

  Widget _healthLine(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: TWSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(top: 6, right: TWSpace.sm),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Expanded(child: Text(text, style: TWType.caption)),
        ],
      ),
    );
  }

  Color _actionColor(String action) {
    switch (action.toUpperCase()) {
      case 'ADD':
        return TWColors.up;
      case 'REDUCE':
        return TWColors.warn;
      case 'EXIT':
        return TWColors.down;
      default:
        return TWColors.textTertiary;
    }
  }

  // Flat section (no card box): Stockbits-style header + hairline-separated
  // rows, matching the Home layout. Replaces the boxed Rebalancing AI card.
  Widget _rebalanceSection(RebalanceReport r) {
    // Only show actions for symbols still held (client-side safety net).
    final held = _positions.map((p) => '${p.symbol}@US').toSet();
    final report = r.reconciledWith(held);
    final allActed = report.actions.where((a) => a.action != 'HOLD').toList();
    // Rows whose implied side already has a pending order in flight.
    bool isPending(RebalanceAction a) =>
        _pendingOrderFor(a.symbol, _rebSide(a)) != null;
    final pendingCount = allActed.where(isPending).length;
    // Optionally filter out rows the user has already executed (pending), so
    // they stop nagging after the order is queued.
    final acted = _hidePendingReb
        ? allActed.where((a) => !isPending(a)).toList()
        : allActed;
    return Column(
      key: const Key('moomoo_rebalance_card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, thickness: 1, color: TWColors.hairlineTop),
        const SizedBox(height: TWSpace.md),
        Row(
          children: [
            const Expanded(child: Text('Rebalancing AI', style: TWType.body)),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: TWSpace.sm,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: TWColors.accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(TWRadius.chip),
              ),
              child: Text(
                report.profile,
                style: TWType.overline.copyWith(color: TWColors.accentBright),
              ),
            ),
            if (acted.isNotEmpty)
              _toggleChip(
                const Key('moomoo_toggle_rebalance'),
                _hideRebalance,
                () => _toggleHide(
                  _kHideRebalancePref,
                  _hideRebalance,
                  (v) => _hideRebalance = v,
                ),
              ),
          ],
        ),
        if (report.summary.isNotEmpty) ...[
          const SizedBox(height: TWSpace.sm),
          Text(report.summary, style: TWType.caption),
        ],
        // Pending-order filter: when any action already has an order in
        // flight, offer to hide those rows so they stop nagging.
        if (pendingCount > 0 && !_hideRebalance) ...[
          const SizedBox(height: TWSpace.sm),
          Row(
            children: [
              const Icon(Icons.hourglass_top,
                  size: 14, color: TWColors.warn),
              const SizedBox(width: TWSpace.xs),
              Expanded(
                child: Text(
                  '$pendingCount action(s) already have a pending order '
                  '(waiting to fill).',
                  style: TWType.caption
                      .copyWith(color: TWColors.textSecondary),
                ),
              ),
              GestureDetector(
                key: const Key('moomoo_reb_hide_pending'),
                onTap: () => _toggleHide(
                  _kHidePendingRebPref,
                  _hidePendingReb,
                  (v) => _hidePendingReb = v,
                ),
                child: Text(
                  _hidePendingReb ? 'Show pending' : 'Hide pending',
                  style: TWType.caption.copyWith(color: TWColors.accentBright),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: TWSpace.md),
        if (acted.isEmpty)
          Text(
            pendingCount > 0 && _hidePendingReb
                ? 'All actions have pending orders — waiting to fill.'
                : 'No rebalancing actions — portfolio looks balanced.',
            style: TWType.caption,
          )
        else if (_hideRebalance)
          Text('Rebalancing actions hidden.', style: TWType.caption)
        else
          for (var i = 0; i < acted.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 1,
                color: TWColors.hairlineTop,
              ),
            _rebalanceTile(acted[i]),
          ],
        if (!_hideRebalance)
          for (final w in report.warnings) _healthLine(w, TWColors.warn),
      ],
    );
  }

  Widget _rebalanceTile(RebalanceAction a) {
    final color = _actionColor(a.action);
    // The position behind this action (if still held) gives us the sell
    // amount and last price for the inline sell slider.
    final pos = _positionFor(a.symbol);
    final canSell = pos?.canSellQty ?? 0;
    final rebSellOpen = _rebSellExpanded == a.symbol;
    final rebBuyOpen = _rebBuyExpanded == a.symbol;
    // Tap target side: ADD -> BUY, REDUCE/EXIT -> SELL, else default BUY.
    final tapSide = a.action.toUpperCase() == 'ADD' ? 'BUY' : 'SELL';
    // A still-working order for this row's implied side (e.g. an ADD/EXIT the
    // user already submitted while the market was closed). When present we
    // flag the row and disable that side's button to prevent double-submits.
    final pending = _pendingOrderFor(a.symbol, tapSide);
    final isPending = pending != null;
    return Padding(
      key: Key('moomoo_reb_${a.symbol}'),
      padding: const EdgeInsets.symmetric(vertical: TWSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tap the row to open the order ticket prefilled for this symbol
          // and the rebalance-implied side.
          InkWell(
            key: Key('moomoo_reb_tap_${a.symbol}'),
            borderRadius: BorderRadius.circular(TWRadius.chip),
            onTap: () => _openTicket(a.symbol, tapSide),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: TWSpace.sm,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(TWRadius.chip),
                    ),
                    child: Text(
                      a.action,
                      style: TWType.overline.copyWith(color: color),
                    ),
                  ),
                  const SizedBox(width: TWSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${a.symbol} · ${a.currentWeight.toStringAsFixed(0)}% '
                          '→ ${a.targetWeight.toStringAsFixed(0)}%',
                          style: TWType.label,
                        ),
                        if (a.pnlValue != 0 || a.pnlPct != 0) ...[
                          const SizedBox(height: 2),
                          Text(
                            _pnlText(a.pnlPct, a.pnlValue),
                            style: TWType.caption.copyWith(
                              color: a.pnlValue >= 0
                                  ? TWColors.up
                                  : TWColors.down,
                            ),
                          ),
                        ],
                        if (a.reason.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(a.reason, style: TWType.caption),
                        ],
                      ],
                    ),
                  ),
                  if (isPending)
                    Container(
                      key: Key('moomoo_reb_pending_${a.symbol}'),
                      margin: const EdgeInsets.only(right: TWSpace.xs),
                      padding: const EdgeInsets.symmetric(
                        horizontal: TWSpace.sm,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: TWColors.warn.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(TWRadius.chip),
                      ),
                      child: Text(
                        'Pending',
                        style: TWType.overline.copyWith(color: TWColors.warn),
                      ),
                    ),
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: TWColors.textTertiary,
                  ),
                ],
              ),
            ),
          ),
          // Buy / Sell buttons. Each toggles its OWN inline quantity slider,
          // shown only AFTER the side is tapped; opening one collapses the
          // other. Mirrors the Positions tile behaviour.
          const SizedBox(height: TWSpace.sm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: Key('moomoo_reb_buy_${a.symbol}'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TWColors.up,
                    side: BorderSide(
                      color: rebBuyOpen ? TWColors.up : TWColors.hairlineTop,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: TWSpace.sm),
                  ),
                  onPressed: (isPending && tapSide == 'BUY')
                      ? null
                      : () => setState(() {
                          _rebBuyExpanded = rebBuyOpen ? null : a.symbol;
                          _rebSellExpanded = null;
                        }),
                  child: Text(
                    (isPending && tapSide == 'BUY') ? 'Buy · Pending' : 'Buy',
                    style: TWType.label,
                  ),
                ),
              ),
              const SizedBox(width: TWSpace.sm),
              Expanded(
                child: OutlinedButton(
                  key: Key('moomoo_reb_sell_${a.symbol}'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TWColors.down,
                    side: BorderSide(
                      color:
                          rebSellOpen ? TWColors.down : TWColors.hairlineTop,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: TWSpace.sm),
                  ),
                  onPressed: (isPending && tapSide == 'SELL')
                      ? null
                      : canSell > 0
                          ? () => setState(() {
                              _rebSellExpanded = rebSellOpen ? null : a.symbol;
                              _rebBuyExpanded = null;
                            })
                          : () => _openTicket(a.symbol, 'SELL'),
                  child: Text(
                    (isPending && tapSide == 'SELL')
                        ? 'Sell · Pending'
                        : 'Sell',
                    style: TWType.label,
                  ),
                ),
              ),
            ],
          ),
          // Inline SELL slider for held shares: pick how many to sell, confirm.
          if (rebSellOpen && canSell > 0) ...[
            const SizedBox(height: TWSpace.sm),
            _PositionTradeSlider(
              key: Key('moomoo_reb_slider_${a.symbol}'),
              symbol: a.symbol,
              side: 'SELL',
              maxQty: canSell,
              lastPrice: pos?.lastPrice ?? 0,
              onConfirm: (qty) => _openTicket(a.symbol, 'SELL', qty),
            ),
          ],
          // Inline BUY slider: pick how many shares to add, then confirm.
          if (rebBuyOpen) ...[
            const SizedBox(height: TWSpace.sm),
            _PositionTradeSlider(
              key: Key('moomoo_reb_buy_slider_${a.symbol}'),
              symbol: a.symbol,
              side: 'BUY',
              maxQty: (pos?.quantity ?? 0) > 0 ? pos!.quantity : 1,
              lastPrice: pos?.lastPrice ?? 0,
              onConfirm: (qty) => _openTicket(a.symbol, 'BUY', qty),
            ),
          ],
        ],
      ),
    );
  }

  /// The live position for [symbol], or null if not currently held.
  MoomooLivePosition? _positionFor(String symbol) {
    for (final p in _positions) {
      if (p.symbol == symbol) return p;
    }
    return null;
  }

  /// A still-working order for [symbol] on the side this rebalance action
  /// implies (ADD -> BUY, REDUCE/EXIT -> SELL), or null if none is in flight.
  /// Used to flag rows the user has already executed but that are pending
  /// (e.g. submitted while the market was closed).
  MoomooLiveOpenOrder? _pendingOrderFor(String symbol, String side) {
    final want = side.toUpperCase();
    for (final o in _openOrders) {
      if (o.symbol == symbol && o.side == want) return o;
    }
    return null;
  }

  // The side a rebalance action implies: ADD -> BUY, REDUCE/EXIT -> SELL.
  String _rebSide(RebalanceAction a) =>
      a.action.toUpperCase() == 'ADD' ? 'BUY' : 'SELL';

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  /// The ACTIVE server-managed SL/TP bracket for [symbol], or null.
  MoomooLiveBracket? _bracketFor(String symbol) {
    for (final b in _brackets) {
      if (b.symbol == symbol && b.isActive) return b;
    }
    return null;
  }

  // Flat section (no card box): Stockbits-style header + hairline rows,
  // matching Home. Replaces the boxed Portfolio Manager card.
  Widget _managerSection(MoomooLiveManagerReport m) {
    final riskColor = _riskColor(m.riskLevel);
    return Column(
      key: const Key('moomoo_manager_card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, thickness: 1, color: TWColors.hairlineTop),
        const SizedBox(height: TWSpace.md),
        Row(
          children: [
            const Expanded(
              child: Text('Portfolio Manager', style: TWType.body),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: TWSpace.sm,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: riskColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(TWRadius.chip),
              ),
              child: Text(
                '${m.riskLevel} risk',
                style: TWType.overline.copyWith(color: riskColor),
              ),
            ),
            if (m.recommendations.isNotEmpty)
              _toggleChip(
                const Key('moomoo_toggle_manager'),
                _hideManager,
                () => _toggleHide(
                  _kHideManagerPref,
                  _hideManager,
                  (v) => _hideManager = v,
                ),
              ),
          ],
        ),
        const SizedBox(height: TWSpace.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _scoreChip('Diversif.', m.diversificationScore),
            _scoreChip('Concentr.', m.concentrationScore),
            _scoreChip('Cash %', m.cashPct),
            _scoreChip('Top pos %', m.largestPositionPct),
          ],
        ),
        if (m.recommendations.isNotEmpty && !_hideManager) ...[
          const Divider(height: TWSpace.lg, color: TWColors.hairline),
          for (var i = 0; i < m.recommendations.length; i++)
            _recTile(m.recommendations[i], i),
        ],
      ],
    );
  }

  Widget _recTile(MoomooLiveManagerRec r, int index) {
    final color = _sevColor(r.severity);
    // Live data can return many recommendations of the same kind (e.g. several
    // 'weak_position' rows), so the index keeps each tile key unique — a
    // duplicate key crashes the card and breaks its hide toggle.
    return Padding(
      key: Key('moomoo_rec_${r.kind}_$index'),
      padding: const EdgeInsets.only(bottom: TWSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_sevIcon(r.kind), color: color, size: 18),
          const SizedBox(width: TWSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.symbol != null && r.symbol!.isNotEmpty
                      ? '${r.title} · ${r.symbol}'
                      : r.title,
                  style: TWType.label.copyWith(color: color),
                ),
                const SizedBox(height: 2),
                Text(r.message, style: TWType.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -- portfolio-growth chart ------------------------------------------

  /// Real-equity growth chart (Stockbits-style: hero value + delta, clean
  /// line + soft area fill). Built only from genuine recorded observations.
  Widget _growthCard(List<MoomooLiveEquityPoint> points) {
    final first = points.first.equity;
    final last = points.last.equity;
    final delta = last - first;
    final pct = first > 0 ? (delta / first * 100.0) : 0.0;
    final up = delta >= 0;
    final color = up ? TWColors.up : TWColors.down;
    final currency = _account?.currency ?? 'USD';
    final span = _spanLabel(points.first.time, points.last.time);

    return _card(
      key: const Key('moomoo_growth_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Portfolio growth', style: TWType.overline),
          const SizedBox(height: TWSpace.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_money(last, currency), style: TWType.title3),
              const SizedBox(width: TWSpace.sm),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      up ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                      color: color,
                      size: 18,
                    ),
                    Text(
                      '${up ? '+' : '-'}${_money(delta.abs(), currency)} '
                      '(${pct.abs().toStringAsFixed(2)}%)',
                      style: TWType.caption.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: TWSpace.md),
          SizedBox(
            height: 132,
            width: double.infinity,
            child: CustomPaint(
              painter: _GrowthChartPainter(
                values: points.map((p) => p.equity).toList(),
                color: color,
              ),
            ),
          ),
          const SizedBox(height: TWSpace.xs),
          Text(
            span,
            style: TWType.caption.copyWith(color: TWColors.textTertiary),
          ),
        ],
      ),
    );
  }

  static String _spanLabel(DateTime a, DateTime b) {
    String d(DateTime t) =>
        '${t.day.toString().padLeft(2, '0')}/'
        '${t.month.toString().padLeft(2, '0')}';
    final days = b.difference(a).inDays;
    if (days <= 0) return 'Today';
    return '${d(a)} → ${d(b)} · $days day${days == 1 ? '' : 's'}';
  }

  Widget _accountCard() {
    final a = _account;
    return _card(
      key: const Key('moomoo_account_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Account', style: TWType.title3)),
              if (_loading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: TWSpace.md),
          if (a == null && !_loading)
            Text('Pull to refresh.', style: TWType.caption)
          else if (a != null) ...[
            _kv('Total assets', _money(a.totalAssets, a.currency)),
            _kv('Cash', _money(a.cash, a.currency)),
            _kv('Buying power', _money(a.buyingPower, a.currency)),
            _kv('Market value', _money(a.marketValue, a.currency)),
            // Realized gain (broker-reported, booked from closed positions)
            // and total unrealized P/L across open positions (summed from the
            // broker's per-position values; no extra fetch).
            const Divider(height: TWSpace.lg, color: TWColors.hairline),
            _kvPL('Realized gain', a.realizedPl, 0, a.currency),
            if (_positions.isNotEmpty)
              _kvPL('Unrealized P/L', _totalPlVal, _totalPlRatio, a.currency),
          ],
        ],
      ),
    );
  }

  Widget _positionsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The title sits on its own line so it never gets squeezed by the
        // action pills; the pills wrap onto the line(s) below it.
        Padding(
          padding: const EdgeInsets.only(left: TWSpace.xs, bottom: TWSpace.xs),
          child: Text(
            'Positions (${_positions.length})',
            style: TWType.overline,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: TWSpace.xs, bottom: TWSpace.xs),
          child: Wrap(
            spacing: TWSpace.xs,
            runSpacing: TWSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // SL/TP plan settings: lets the owner change the stop/target %
              // used by both Protect and Protect-all.
              if (widget.secretStore.hasSecret && _positions.isNotEmpty)
                InkWell(
                  key: const Key('moomoo_sltp_settings_open'),
                  onTap: _editSltpSettings,
                  borderRadius: BorderRadius.circular(TWRadius.chip),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: TWSpace.sm,
                      vertical: TWSpace.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.tune,
                          size: 16,
                          color: TWColors.textTertiary,
                        ),
                        const SizedBox(width: TWSpace.xs),
                        Text(
                          _sltpLabel,
                          key: const Key('moomoo_sltp_plan_label'),
                          style: TWType.overline.copyWith(
                            color: TWColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Protect-all: batch on/off for the configured SL/TP brackets
              // across every position. Only the owner (secret present) sees it.
              if (widget.secretStore.hasSecret && _positions.isNotEmpty)
                InkWell(
                  key: const Key('moomoo_sltp_protect_all'),
                  onTap: _protectAllBusy
                      ? null
                      : () => _toggleProtectAll(!_allProtected),
                  borderRadius: BorderRadius.circular(TWRadius.chip),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: TWSpace.sm,
                      vertical: TWSpace.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _allProtected
                              ? Icons.shield
                              : Icons.shield_outlined,
                          size: 16,
                          color: _allProtected
                              ? TWColors.accentBright
                              : TWColors.textTertiary,
                        ),
                        const SizedBox(width: TWSpace.xs),
                        Text(
                          _allProtected ? 'Protected' : 'Protect all',
                          style: TWType.overline.copyWith(
                            color: _allProtected
                                ? TWColors.accentBright
                                : TWColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Take-profit-all: only meaningful when there's something to sell.
              if (widget.secretStore.hasSecret && _positions.isNotEmpty)
                InkWell(
                  key: const Key('moomoo_trim_open'),
                  onTap: _openTrimSheet,
                  borderRadius: BorderRadius.circular(TWRadius.chip),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: TWSpace.sm,
                      vertical: TWSpace.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.content_cut,
                          size: 16,
                          color: TWColors.up,
                        ),
                        const SizedBox(width: TWSpace.xs),
                        Text(
                          'Trim',
                          style: TWType.overline.copyWith(color: TWColors.up),
                        ),
                      ],
                    ),
                  ),
                ),
              InkWell(
                key: const Key('moomoo_toggle_positions'),
                onTap: _toggleHidePositions,
                borderRadius: BorderRadius.circular(TWRadius.chip),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: TWSpace.sm,
                    vertical: TWSpace.xs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _hidePositions
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 16,
                        color: TWColors.textTertiary,
                      ),
                      const SizedBox(width: TWSpace.xs),
                      Text(
                        _hidePositions ? 'Show' : 'Hide',
                        style: TWType.overline.copyWith(
                          color: TWColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!_hidePositions && _positions.length > 1) _positionsSortBar(),
        if (_hidePositions)
          _card(child: Text('Positions hidden.', style: TWType.caption))
        else if (_positions.isEmpty)
          _card(child: Text('No open positions.', style: TWType.caption))
        else
          ..._sortedPositions.map(_positionTile),
      ],
    );
  }

  /// Sort chips for the Positions list: P/L high->low and Weight high->low.
  /// Tapping the active chip returns to the broker's default order.
  Widget _positionsSortBar() {
    return Padding(
      padding: const EdgeInsets.only(
        left: TWSpace.xs, right: TWSpace.xs, bottom: TWSpace.sm,
      ),
      child: Row(
        children: [
          Text('Sort', style: TWType.overline),
          const SizedBox(width: TWSpace.sm),
          _sortChip('moomoo_sort_pl', 'P/L', 'pl'),
          const SizedBox(width: TWSpace.xs),
          _sortChip('moomoo_sort_weight', 'Weight', 'weight'),
        ],
      ),
    );
  }

  Widget _sortChip(String keyName, String label, String mode) {
    final active = _posSort == mode;
    return InkWell(
      key: Key(keyName),
      onTap: () => _setPosSort(mode),
      borderRadius: BorderRadius.circular(TWRadius.chip),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.sm, vertical: TWSpace.xs,
        ),
        decoration: BoxDecoration(
          color: active ? TWColors.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(TWRadius.chip),
          border: Border.all(
            color: active ? TWColors.accent : TWColors.hairlineTop,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TWType.overline.copyWith(
                color: active ? TWColors.textPrimary : TWColors.textTertiary,
              ),
            ),
            if (active) ...[
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_downward,
                size: 12,
                color: TWColors.textPrimary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _positionTile(MoomooLivePosition p) {
    final up = p.plVal >= 0;
    final canSell = p.canSellQty;
    final sellOpen = _sellExpanded == p.symbol;
    final buyOpen = _buyExpanded == p.symbol;
    return Padding(
      padding: const EdgeInsets.only(bottom: TWSpace.sm),
      child: _card(
        key: Key('moomoo_pos_${p.symbol}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.symbol, style: TWType.label),
                      const SizedBox(height: 2),
                      Text(
                        '${_qty(p.quantity)} @ ${_money(p.lastPrice, "USD")}',
                        style: TWType.caption,
                      ),
                      if (p.costPrice > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Avg cost ${_money(p.costPrice, "USD")}',
                          style: TWType.caption,
                        ),
                      ],
                      // Equity tied up in this name: what you paid in
                      // (qty * avg cost) and its value now (qty * last price).
                      if (p.costPrice > 0 && p.quantity > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Invested ${_money(p.quantity * p.costPrice, "USD")}'
                          ' · now ${_money(p.quantity * p.lastPrice, "USD")}',
                          style: TWType.caption.copyWith(
                            color: TWColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${up ? '+' : '-'}${_money(p.plVal.abs(), "USD")}',
                      style: TWType.label.copyWith(
                        color: up ? TWColors.up : TWColors.down,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${up ? '+' : ''}${(p.plRatio * 100).toStringAsFixed(2)}%',
                      style: TWType.caption.copyWith(
                        color: up ? TWColors.up : TWColors.down,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            // Server-managed stop-loss / take-profit ("bracket"). Shows the
            // active bracket if one is attached, else a one-tap action to
            // protect the position with a -1% stop / +3% target.
            const SizedBox(height: TWSpace.sm),
            _bracketRow(p),
            // Buy / Sell buttons. Each one toggles its OWN inline quantity
            // slider; the slider only appears AFTER the side is tapped, and
            // opening one side collapses the other.
            const SizedBox(height: TWSpace.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: Key('moomoo_pos_buy_${p.symbol}'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: TWColors.up,
                      side: BorderSide(
                        color: buyOpen ? TWColors.up : TWColors.hairlineTop,
                      ),
                      padding:
                          const EdgeInsets.symmetric(vertical: TWSpace.sm),
                    ),
                    onPressed: () => setState(() {
                      _buyExpanded = buyOpen ? null : p.symbol;
                      _sellExpanded = null;
                    }),
                    child: const Text('Buy', style: TWType.label),
                  ),
                ),
                const SizedBox(width: TWSpace.sm),
                Expanded(
                  child: OutlinedButton(
                    key: Key('moomoo_pos_sell_${p.symbol}'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: TWColors.down,
                      side: BorderSide(
                        color: sellOpen ? TWColors.down : TWColors.hairlineTop,
                      ),
                      padding:
                          const EdgeInsets.symmetric(vertical: TWSpace.sm),
                    ),
                    onPressed: canSell > 0
                        ? () => setState(() {
                            _sellExpanded = sellOpen ? null : p.symbol;
                            _buyExpanded = null;
                          })
                        : () => _openTicket(p.symbol, 'SELL'),
                    child: const Text('Sell', style: TWType.label),
                  ),
                ),
              ],
            ),
            // Inline SELL slider: drag to choose how many held shares to sell
            // (defaults to the full sellable amount), then confirm.
            if (sellOpen && canSell > 0) ...[
              const SizedBox(height: TWSpace.sm),
              _PositionTradeSlider(
                key: Key('moomoo_pos_slider_${p.symbol}'),
                symbol: p.symbol,
                side: 'SELL',
                maxQty: canSell,
                lastPrice: p.lastPrice,
                onConfirm: (qty) => _openTicket(p.symbol, 'SELL', qty),
              ),
            ],
            // Inline BUY slider: drag to choose how many shares to add, then
            // confirm to open the prefilled order ticket on the BUY side.
            if (buyOpen) ...[
              const SizedBox(height: TWSpace.sm),
              _PositionTradeSlider(
                key: Key('moomoo_pos_buy_slider_${p.symbol}'),
                symbol: p.symbol,
                side: 'BUY',
                maxQty: p.quantity > 0 ? p.quantity : 1,
                lastPrice: p.lastPrice,
                onConfirm: (qty) => _openTicket(p.symbol, 'BUY', qty),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The SL/TP bracket row for a position tile: shows the active bracket's
  /// stop / target prices (and which leg fires next), or a one-tap action to
  /// protect the position with the default -1% / +3% plan.
  Widget _bracketRow(MoomooLivePosition p) {
    final b = _bracketFor(p.symbol);
    if (b != null) {
      return Container(
        key: Key('moomoo_sltp_active_${p.symbol}'),
        padding: const EdgeInsets.symmetric(
            horizontal: TWSpace.md, vertical: TWSpace.sm),
        decoration: BoxDecoration(
          color: TWColors.accent.withValues(alpha: 0.10),
          borderRadius: TWRadius.rSm,
          border: Border.all(color: TWColors.accent.withValues(alpha: 0.30)),
        ),
        child: Row(
          children: [
            const Icon(Icons.shield_outlined,
                size: 16, color: TWColors.accentBright),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Protected · SL ${_money(b.stopPrice, "USD")}'
                ' (${b.stopPct.toStringAsFixed(b.stopPct % 1 == 0 ? 0 : 2)}%)'
                ' · TP ${_money(b.targetPrice, "USD")}'
                ' (+${b.targetPct.toStringAsFixed(b.targetPct % 1 == 0 ? 0 : 2)}%)',
                style: TWType.caption.copyWith(color: TWColors.textSecondary),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              key: Key('moomoo_sltp_cancel_${p.symbol}'),
              onTap: () => _cancelBracket(p.symbol),
              child: Text(
                'Remove',
                style: TWType.caption.copyWith(color: TWColors.down),
              ),
            ),
          ],
        ),
      );
    }
    // Use the average cost as the reference when known (so the plan brackets
    // the entry); fall back to the last price for a fresh ad-hoc protect.
    final ref = p.costPrice > 0 ? p.costPrice : p.lastPrice;
    return OutlinedButton.icon(
      key: Key('moomoo_sltp_add_${p.symbol}'),
      style: OutlinedButton.styleFrom(
        foregroundColor: TWColors.accentBright,
        side: const BorderSide(color: TWColors.hairlineTop),
        padding: const EdgeInsets.symmetric(vertical: TWSpace.sm),
      ),
      onPressed: ref > 0 ? () => _attachBracketSheet(p, ref) : null,
      icon: const Icon(Icons.shield_outlined, size: 16),
      label: Text('Protect · $_sltpLabel', style: TWType.label),
    );
  }

  /// Confirm + attach a server-managed SL/TP bracket on [p] using the trader's
  /// configured stop/target percentages.
  Future<void> _attachBracketSheet(
      MoomooLivePosition p, double ref) async {
    final stop = ref * (1.0 + _stopPct / 100.0);
    final target = ref * (1.0 + _targetPct / 100.0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TWColors.surfaceCard,
        title: Text('Protect ${p.symbol}', style: TWType.label),
        content: Text(
          'TradeWizz will watch the live price and place a MARKET SELL of '
          '${_qty(p.canSellQty > 0 ? p.canSellQty : p.quantity)} '
          '${p.symbol} when either level is hit:\n\n'
          '· Stop-loss at ${_money(stop, "USD")}'
          ' (${_stopPct.toStringAsFixed(_stopPct % 1 == 0 ? 0 : 2)}%)\n'
          '· Take-profit at ${_money(target, "USD")}'
          ' (+${_targetPct.toStringAsFixed(_targetPct % 1 == 0 ? 0 : 2)}%)\n\n'
          'Whichever fires first cancels the other. This sells real shares.',
          style: TWType.caption.copyWith(color: TWColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('moomoo_sltp_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Protect'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final token = _token;
    final secret = widget.secretStore.secret;
    if (token == null || secret == null) return;
    try {
      final qty = p.canSellQty > 0 ? p.canSellQty : p.quantity;
      final b = await widget.repository.moomooAttachBracket(
        token: token,
        secret: secret,
        symbol: p.symbol,
        quantity: qty,
        referencePrice: ref,
        stopPct: _stopPct,
        targetPct: _targetPct,
      );
      if (!mounted) return;
      setState(() {
        _brackets = [
          ..._brackets.where((x) => x.symbol != p.symbol),
          b,
        ];
      });
      _toast('Protecting ${p.symbol}: SL ${_money(b.stopPrice, "USD")}'
          ' / TP ${_money(b.targetPrice, "USD")}');
    } on ApiException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  Future<void> _cancelBracket(String symbol) async {
    final token = _token;
    final secret = widget.secretStore.secret;
    if (token == null || secret == null) return;
    try {
      await widget.repository.moomooCancelBracket(
        token: token,
        secret: secret,
        symbol: symbol,
      );
      if (!mounted) return;
      setState(() {
        _brackets = _brackets.where((x) => x.symbol != symbol).toList();
      });
      _toast('Removed protection for $symbol');
    } on ApiException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  /// True when every open position currently has an active -1% / +3% bracket.
  /// Used to drive the "Protect all" toggle's on/off state.
  bool get _allProtected =>
      _positions.isNotEmpty &&
      _positions.every((p) => _bracketFor(p.symbol) != null);

  /// Toggle server-managed protection across ALL positions at once. Turning it
  /// on attaches a -1% / +3% bracket to every still-unprotected position;
  /// turning it off removes protection from every protected position. Real
  /// money, so a single confirmation covers the whole batch.
  Future<void> _toggleProtectAll(bool on) async {
    if (_protectAllBusy) return;
    final token = _token;
    final secret = widget.secretStore.secret;
    if (token == null || secret == null) return;

    if (on) {
      final targets = _positions
          .where((p) =>
              _bracketFor(p.symbol) == null &&
              (p.costPrice > 0 ? p.costPrice : p.lastPrice) > 0)
          .toList();
      if (targets.isEmpty) {
        _toast('Nothing to protect.');
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: TWColors.surfaceCard,
          title: const Text('Protect all positions', style: TWType.label),
          content: Text(
            'TradeWizz will watch the live price for ${targets.length} '
            '${targets.length == 1 ? 'position' : 'positions'} and place a '
            'MARKET SELL when each hits its stop-loss '
            '(${_stopPct.toStringAsFixed(_stopPct % 1 == 0 ? 0 : 2)}%) or '
            'take-profit '
            '(+${_targetPct.toStringAsFixed(_targetPct % 1 == 0 ? 0 : 2)}%). '
            'This sells real shares.',
            style: TWType.caption.copyWith(color: TWColors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('moomoo_sltp_protect_all_confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Protect all'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;

      setState(() => _protectAllBusy = true);
      var done = 0;
      var failed = 0;
      for (final p in targets) {
        final ref = p.costPrice > 0 ? p.costPrice : p.lastPrice;
        final qty = p.canSellQty > 0 ? p.canSellQty : p.quantity;
        try {
          final b = await widget.repository.moomooAttachBracket(
            token: token,
            secret: secret,
            symbol: p.symbol,
            quantity: qty,
            referencePrice: ref,
            stopPct: _stopPct,
            targetPct: _targetPct,
          );
          if (!mounted) return;
          setState(() {
            _brackets = [
              ..._brackets.where((x) => x.symbol != p.symbol),
              b,
            ];
          });
          done++;
        } on ApiException {
          failed++;
        }
      }
      if (!mounted) return;
      setState(() => _protectAllBusy = false);
      _toast(failed == 0
          ? 'Protected $done '
              '${done == 1 ? 'position' : 'positions'} ($_sltpLabel)'
          : 'Protected $done, $failed could not be protected');
    } else {
      final protectedSyms = _positions
          .map((p) => p.symbol)
          .where((s) => _bracketFor(s) != null)
          .toList();
      if (protectedSyms.isEmpty) return;

      setState(() => _protectAllBusy = true);
      var removed = 0;
      for (final sym in protectedSyms) {
        try {
          await widget.repository.moomooCancelBracket(
            token: token,
            secret: secret,
            symbol: sym,
          );
          if (!mounted) return;
          setState(() {
            _brackets = _brackets.where((x) => x.symbol != sym).toList();
          });
          removed++;
        } on ApiException {
          /* leave that bracket in place; user can retry */
        }
      }
      if (!mounted) return;
      setState(() => _protectAllBusy = false);
      _toast('Removed protection from $removed '
          '${removed == 1 ? 'position' : 'positions'}');
    }
  }

  /// Positions in the user-selected order. 'default' preserves the broker's
  /// ordering; 'pl' sorts by unrealized P/L high->low; 'weight' sorts by
  /// market value (quantity * last price) high->low. A stable copy is returned
  /// so the underlying [_positions] list is never mutated in place.
  List<MoomooLivePosition> get _sortedPositions {
    if (_posSort == 'default') return _positions;
    final list = List<MoomooLivePosition>.from(_positions);
    if (_posSort == 'pl') {
      list.sort((a, b) => b.plVal.compareTo(a.plVal));
    } else if (_posSort == 'weight') {
      double mv(MoomooLivePosition p) => p.quantity * p.lastPrice;
      list.sort((a, b) => mv(b).compareTo(mv(a)));
    }
    return list;
  }

  /// Total unrealized P/L = sum of each position's broker-reported pl_val.
  double get _totalPlVal => _positions.fold(0.0, (sum, p) => sum + p.plVal);

  /// Total cost basis = sum(qty * cost_price). Used only to derive an overall
  /// P/L %; falls back to 0 (hidden %) when unavailable.
  double get _totalCostBasis =>
      _positions.fold(0.0, (sum, p) => sum + p.quantity * p.costPrice);

  /// Overall P/L ratio (fraction, e.g. 0.0125 = +1.25%). 0 when no cost basis.
  double get _totalPlRatio {
    final cost = _totalCostBasis;
    return cost > 0 ? _totalPlVal / cost : 0;
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(k, style: TWType.caption),
        Text(v, style: TWType.tabular(TWType.label)),
      ],
    ),
  );

  /// Colored P/L row: green when up, red when down, with signed amount and
  /// (optionally) percentage.
  Widget _kvPL(String k, double plVal, double plRatio, String currency) {
    final up = plVal >= 0;
    final color = up ? TWColors.up : TWColors.down;
    final amount = '${up ? '+' : '-'}${_money(plVal.abs(), currency)}';
    final pct = plRatio != 0
        ? '  (${up ? '+' : ''}${(plRatio * 100).toStringAsFixed(2)}%)'
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: TWType.caption),
          Text(
            '$amount$pct',
            style: TWType.tabular(TWType.label).copyWith(color: color),
          ),
        ],
      ),
    );
  }

  Widget _card({Key? key, required Widget child}) => Container(
    key: key,
    width: double.infinity,
    padding: const EdgeInsets.all(TWSpace.lg),
    decoration: BoxDecoration(
      color: TWColors.surfaceCard.withValues(alpha: 0.55),
      borderRadius: TWRadius.rCard,
      border: Border.all(color: TWColors.hairline),
    ),
    child: child,
  );

  static String _money(double v, String currency) {
    final sym = currency == 'USD' ? '\$' : '';
    return '$sym${v.toStringAsFixed(2)}';
  }

  static String _qty(double q) {
    if (q == q.roundToDouble()) return q.toStringAsFixed(0);
    return q.toString();
  }

  // Unrealized P/L line for a rebalance action: "+12.3% (+$1,234.56)".
  static String _pnlText(double pct, double value) {
    final sign = value >= 0 ? '+' : '-';
    return '$sign${pct.abs().toStringAsFixed(1)}% '
        '($sign${_money(value.abs(), "USD")})';
  }
}

/// Inline single-side quantity slider for a Positions tile. Shown only AFTER
/// the user taps Buy or Sell on that tile. Drag to choose a quantity (defaults
/// to [maxQty]) then tap the confirm button to open the prefilled order ticket
/// on [side] ('BUY' or 'SELL').
class _PositionTradeSlider extends StatefulWidget {
  const _PositionTradeSlider({
    super.key,
    required this.symbol,
    required this.side,
    required this.maxQty,
    required this.lastPrice,
    required this.onConfirm,
  });

  final String symbol;
  final String side; // 'BUY' or 'SELL'
  final double maxQty;
  final double lastPrice;
  final void Function(double qty) onConfirm;

  @override
  State<_PositionTradeSlider> createState() => _PositionTradeSliderState();
}

class _PositionTradeSliderState extends State<_PositionTradeSlider> {
  late double _qty = widget.maxQty;

  bool get _isBuy => widget.side == 'BUY';
  Color get _color => _isBuy ? TWColors.up : TWColors.down;

  @override
  void didUpdateWidget(_PositionTradeSlider old) {
    super.didUpdateWidget(old);
    if (widget.maxQty != old.maxQty) {
      _qty = _qty.clamp(0, widget.maxQty);
      if (_qty == 0) _qty = widget.maxQty;
    }
  }

  // Whole-share holdings get integer steps; fractional ones keep 4-dp grain.
  bool get _wholeOnly => widget.maxQty == widget.maxQty.roundToDouble();

  double _round(double q) {
    if (_wholeOnly) return q.roundToDouble();
    return (q * 10000).round() / 10000;
  }

  String _fmt(double q) {
    if (q == q.roundToDouble()) return q.toStringAsFixed(0);
    return q.toStringAsFixed(4);
  }

  @override
  Widget build(BuildContext context) {
    final qty = _round(_qty).clamp(0.0, widget.maxQty);
    final pct = widget.maxQty > 0 ? (qty / widget.maxQty * 100) : 0;
    final notional = qty * widget.lastPrice;
    final label = _isBuy ? 'Buy' : 'Sell';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: TWType.caption.copyWith(color: _color)),
            const SizedBox(width: TWSpace.sm),
            Expanded(
              child: Text(
                '${_fmt(qty)} sh · ${pct.toStringAsFixed(0)}%'
                '${widget.lastPrice > 0 ? ' · ≈\$${notional.toStringAsFixed(2)}' : ''}',
                style: TWType.caption.copyWith(color: TWColors.textSecondary),
              ),
            ),
            Text(
              'max ${_fmt(widget.maxQty)}',
              style: TWType.overline.copyWith(color: TWColors.textTertiary),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: _color,
            inactiveTrackColor: TWColors.hairlineTop,
            thumbColor: _color,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            key: Key('moomoo_pos_${widget.side.toLowerCase()}_range_${widget.symbol}'),
            value: qty.toDouble(),
            max: widget.maxQty,
            divisions: _wholeOnly && widget.maxQty <= 100
                ? widget.maxQty.round().clamp(1, 100)
                : 100,
            onChanged: (v) => setState(() => _qty = v),
          ),
        ),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: Key('moomoo_pos_${widget.side.toLowerCase()}_confirm_${widget.symbol}'),
            style: FilledButton.styleFrom(
              backgroundColor: _color,
              padding: const EdgeInsets.symmetric(vertical: TWSpace.sm),
            ),
            onPressed: qty > 0 ? () => widget.onConfirm(qty) : null,
            child: Text(label, style: TWType.label),
          ),
        ),
      ],
    );
  }
}

/// Compact two-segment toggle for the Trim threshold unit: '%' or '$'.
class _TrimModeToggle extends StatelessWidget {
  const _TrimModeToggle({
    required this.mode,
    required this.currency,
    required this.onChanged,
  });

  final String mode; // 'pct' | 'usd'
  final String currency;
  final ValueChanged<String> onChanged;

  String get _dollarGlyph => currency == 'USD' ? '\$' : currency;

  @override
  Widget build(BuildContext context) {
    Widget seg(String value, String label, Key key) {
      final active = mode == value;
      return InkWell(
        key: key,
        onTap: () => onChanged(value),
        borderRadius: BorderRadius.circular(TWRadius.chip),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: TWSpace.md, vertical: TWSpace.xs),
          decoration: BoxDecoration(
            color: active ? TWColors.up : Colors.transparent,
            borderRadius: BorderRadius.circular(TWRadius.chip),
          ),
          child: Text(
            label,
            style: TWType.label.copyWith(
              color: active ? TWColors.surfaceCard : TWColors.textSecondary,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: TWColors.hairlineTop,
        borderRadius: BorderRadius.circular(TWRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg('pct', '%', const Key('moomoo_trim_mode_pct')),
          seg('usd', _dollarGlyph, const Key('moomoo_trim_mode_usd')),
        ],
      ),
    );
  }
}

/// Two-step LIVE order ticket: preview -> confirm. Whole shares only (the
/// backend rejects fractional new orders). MARKET or LIMIT.
class MoomooOrderTicketPage extends StatefulWidget {
  const MoomooOrderTicketPage({
    super.key,
    required this.repository,
    required this.token,
    required this.secret,
    this.prefillSymbol,
    this.prefillSide,
    this.prefillQty,
  });

  final StockRepository repository;
  final String token;
  final String secret;
  final String? prefillSymbol;

  /// Optional preselected side ('BUY' / 'SELL') when launched from a quick
  /// action (e.g. the Rebalancing AI sell slider). Defaults to SELL when a
  /// symbol is prefilled and no side is given (back-compat).
  final String? prefillSide;

  /// Optional preselected quantity when launched from a quick action.
  final double? prefillQty;

  @override
  State<MoomooOrderTicketPage> createState() => _MoomooOrderTicketPageState();
}

enum _MoomooStage { input, confirm, done }

class _MoomooOrderTicketPageState extends State<MoomooOrderTicketPage> {
  final _symbolCtl = TextEditingController();
  final _qtyCtl = TextEditingController(text: '1');
  final _priceCtl = TextEditingController();

  String _side = 'BUY';
  String _orderType = 'MARKET';
  _MoomooStage _stage = _MoomooStage.input;
  bool _busy = false;
  String? _error;
  MoomooLivePreview? _preview;
  MoomooLiveOrderResult? _result;

  @override
  void initState() {
    super.initState();
    if (widget.prefillSymbol != null) {
      _symbolCtl.text = widget.prefillSymbol!;
      _side = widget.prefillSide ?? 'SELL';
    } else if (widget.prefillSide != null) {
      _side = widget.prefillSide!;
    }
    if (widget.prefillQty != null && widget.prefillQty! > 0) {
      _qtyCtl.text = _MoomooLivePageState._qty(widget.prefillQty!);
    }
  }

  @override
  void dispose() {
    _symbolCtl.dispose();
    _qtyCtl.dispose();
    _priceCtl.dispose();
    super.dispose();
  }

  Future<void> _doPreview() async {
    final symbol = _symbolCtl.text.trim().toUpperCase();
    // Normalise a decimal comma to a dot as a safety net (paste / autofill).
    final qty = double.tryParse(_qtyCtl.text.trim().replaceAll(',', '.'));
    final price = double.tryParse(_priceCtl.text.trim().replaceAll(',', '.'));
    if (symbol.isEmpty) {
      setState(() => _error = 'Enter a symbol.');
      return;
    }
    if (qty == null || qty <= 0) {
      setState(() => _error = 'Enter a valid quantity.');
      return;
    }
    // Fractional / odd-lot quantities are only accepted for MARKET orders
    // (matches the backend / Moomoo rule). LIMIT requires whole shares.
    final isFractional = qty != qty.roundToDouble();
    if (isFractional && _orderType != 'MARKET') {
      setState(
        () => _error =
            'Fractional quantities are only allowed for MARKET orders.',
      );
      return;
    }
    if (_orderType == 'LIMIT' && (price == null || price <= 0)) {
      setState(() => _error = 'Limit orders need a positive price.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pv = await widget.repository.moomooPreview(
        token: widget.token,
        secret: widget.secret,
        symbol: symbol,
        side: _side,
        quantity: qty,
        orderType: _orderType,
        price: _orderType == 'LIMIT' ? price : null,
      );
      if (!mounted) return;
      setState(() {
        _preview = pv;
        _stage = _MoomooStage.confirm;
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _doPlace() async {
    final pv = _preview;
    if (pv == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.repository.moomooPlace(
        token: widget.token,
        secret: widget.secret,
        symbol: pv.symbol,
        side: pv.side,
        quantity: pv.quantity,
        orderType: pv.orderType,
        price: pv.orderType == 'LIMIT' ? pv.price : null,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _stage = _MoomooStage.done;
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
        _stage = _MoomooStage.input;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return TWScaffoldBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Live order', style: TWType.title2),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(TWSpace.lg),
            child: switch (_stage) {
              _MoomooStage.input => _inputStage(),
              _MoomooStage.confirm => _confirmStage(),
              _MoomooStage.done => _doneStage(),
            },
          ),
        ),
      ),
    );
  }

  Widget _inputStage() {
    return ListView(
      children: [
        if (_error != null) ...[
          _errorBox(_error!),
          const SizedBox(height: TWSpace.md),
        ],
        _segmented(
          ['BUY', 'SELL'],
          _side,
          (v) => setState(() => _side = v),
          key: const Key('moomoo_side_seg'),
        ),
        const SizedBox(height: TWSpace.md),
        TextField(
          key: const Key('moomoo_symbol_field'),
          controller: _symbolCtl,
          textCapitalization: TextCapitalization.characters,
          style: TWType.body,
          decoration: const InputDecoration(
            labelText: 'Symbol (e.g. INTC)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: TWSpace.md),
        TextField(
          key: const Key('moomoo_qty_field'),
          controller: _qtyCtl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          // Digits plus a single decimal separator. Locales that emit a comma
          // (e.g. Indonesian keyboards) have it normalised to a dot so odd-lot
          // quantities like "0,001" still parse as 0.001.
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            _DecimalQtyFormatter(),
          ],
          style: TWType.body,
          decoration: InputDecoration(
            labelText: _orderType == 'MARKET'
                ? 'Quantity (e.g. 0.001 odd lot or 5)'
                : 'Quantity (whole shares)',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: TWSpace.md),
        _segmented(
          ['MARKET', 'LIMIT'],
          _orderType,
          (v) => setState(() => _orderType = v),
          key: const Key('moomoo_type_seg'),
        ),
        if (_orderType == 'LIMIT') ...[
          const SizedBox(height: TWSpace.md),
          TextField(
            key: const Key('moomoo_price_field'),
            controller: _priceCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: TWType.body,
            decoration: const InputDecoration(
              labelText: 'Limit price',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: TWSpace.xl),
        FilledButton(
          key: const Key('moomoo_preview_button'),
          style: FilledButton.styleFrom(
            backgroundColor: TWColors.accent,
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: _busy ? null : _doPreview,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Review order'),
        ),
      ],
    );
  }

  Widget _confirmStage() {
    final pv = _preview!;
    final overCap = !pv.withinCap && pv.estNotional > 0;
    return ListView(
      children: [
        Container(
          padding: const EdgeInsets.all(TWSpace.md),
          decoration: BoxDecoration(
            color: TWColors.down.withValues(alpha: 0.12),
            borderRadius: TWRadius.rCard,
            border: Border.all(color: TWColors.down.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: TWColors.down,
                size: 20,
              ),
              const SizedBox(width: TWSpace.sm),
              Expanded(
                child: Text(
                  'This places a REAL order with real money.',
                  style: TWType.label.copyWith(color: TWColors.textPrimary),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: TWSpace.lg),
        _row('Action', '${pv.side} ${pv.symbol}'),
        _row('Type', pv.orderType),
        _row('Quantity', _MoomooLivePageState._qty(pv.quantity)),
        if (pv.orderType == 'LIMIT')
          _row('Limit price', '\$${pv.price.toStringAsFixed(2)}'),
        _row('Est. notional', '\$${pv.estNotional.toStringAsFixed(2)}'),
        _row('Per-order cap', '\$${pv.maxNotional.toStringAsFixed(2)}'),
        const SizedBox(height: TWSpace.xl),
        if (overCap)
          _errorBox(
            'Order exceeds the per-order cap. Reduce size and try again.',
          ),
        if (!overCap)
          FilledButton(
            key: const Key('moomoo_confirm_button'),
            style: FilledButton.styleFrom(
              backgroundColor: TWColors.down,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _busy ? null : _doPlace,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text('Place LIVE ${pv.side} order'),
          ),
        const SizedBox(height: TWSpace.md),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() => _stage = _MoomooStage.input),
          child: const Text('Back'),
        ),
      ],
    );
  }

  Widget _doneStage() {
    final r = _result!;
    return ListView(
      children: [
        const SizedBox(height: TWSpace.xl),
        const Icon(Icons.check_circle_outline, color: TWColors.up, size: 56),
        const SizedBox(height: TWSpace.md),
        Center(child: Text('Order submitted', style: TWType.title2)),
        const SizedBox(height: TWSpace.lg),
        _row('Order ID', r.orderId),
        _row('Action', '${r.side} ${r.code}'),
        _row('Quantity', _MoomooLivePageState._qty(r.quantity)),
        if (r.price > 0) _row('Price', '\$${r.price.toStringAsFixed(2)}'),
        _row('Status', r.status),
        const SizedBox(height: TWSpace.xl),
        FilledButton(
          key: const Key('moomoo_done_button'),
          style: FilledButton.styleFrom(
            backgroundColor: TWColors.accent,
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _segmented(
    List<String> options,
    String value,
    ValueChanged<String> onChanged, {
    Key? key,
  }) {
    return SegmentedButton<String>(
      key: key,
      segments: [
        for (final o in options)
          ButtonSegment(
            value: o,
            label: Text(o, style: TWType.label),
          ),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
      showSelectedIcon: false,
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(k, style: TWType.caption),
        Flexible(
          child: Text(
            v,
            style: TWType.tabular(TWType.label),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );

  Widget _errorBox(String message) => Container(
    padding: const EdgeInsets.all(TWSpace.md),
    decoration: BoxDecoration(
      color: TWColors.down.withValues(alpha: 0.12),
      borderRadius: TWRadius.rCard,
      border: Border.all(color: TWColors.down.withValues(alpha: 0.4)),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: TWColors.down, size: 18),
        const SizedBox(width: TWSpace.sm),
        Expanded(child: Text(message, style: TWType.caption)),
      ],
    ),
  );
}

/// Normalises the quantity field to a clean decimal: any comma typed as a
/// decimal separator (common on Indonesian/EU keyboards) becomes a dot, and at
/// most one dot is kept. This guarantees values like "0.001" parse correctly
/// instead of silently dropping the separator and becoming a whole number.
/// Minimal Stockbits-style line + soft area-fill chart for the equity series.
/// No external dependency; flat aesthetic with a single accent colour.
class _GrowthChartPainter extends CustomPainter {
  _GrowthChartPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var lo = values.reduce(math.min);
    var hi = values.reduce(math.max);
    if (hi - lo < 1e-9) {
      // Flat series: pad so the line sits centred, not on the edge.
      hi += 1;
      lo -= 1;
    }
    final range = hi - lo;
    final n = values.length;
    final dx = size.width / (n - 1);

    double x(int i) => dx * i;
    double y(double v) => size.height - ((v - lo) / range) * size.height;

    // Baseline grid (subtle).
    final grid = Paint()
      ..color = TWColors.hairline
      ..strokeWidth = 1;
    for (var g = 0; g <= 2; g++) {
      final gy = size.height * g / 2;
      canvas.drawLine(Offset(0, gy), Offset(size.width, gy), grid);
    }

    final line = Path()..moveTo(x(0), y(values[0]));
    for (var i = 1; i < n; i++) {
      line.lineTo(x(i), y(values[i]));
    }

    // Soft area fill under the line.
    final fill = Path.from(line)
      ..lineTo(x(n - 1), size.height)
      ..lineTo(x(0), size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.0)],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    // Endpoint marker.
    canvas.drawCircle(
      Offset(x(n - 1), y(values.last)),
      3.5,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _GrowthChartPainter old) =>
      old.values != values || old.color != color;
}

class _DecimalQtyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text.replaceAll(',', '.');
    // Keep only the first dot; drop any extras.
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
