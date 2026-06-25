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

class MoomooLivePage extends StatefulWidget {
  const MoomooLivePage({
    super.key,
    required this.repository,
    required this.secretStore,
  });

  final StockRepository repository;
  final MoomooSecretStore secretStore;

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
  // Symbol whose inline sell slider is currently expanded in the Positions
  // list (null = none). Tapping Sell on a tile toggles its slider open/closed.
  String? _sellExpanded;

  String? get _token => AuthScope.read(context).token;

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
      _posSort = prefs.getString(_kPosSortPref) ?? 'default';
    });
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
        _positions = pos;
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
    final acted = report.actions.where((a) => a.action != 'HOLD').toList();
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
        const SizedBox(height: TWSpace.md),
        if (acted.isEmpty)
          Text(
            'No rebalancing actions — portfolio looks balanced.',
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
    // Tap target side: ADD -> BUY, REDUCE/EXIT -> SELL, else default BUY.
    final tapSide = a.action.toUpperCase() == 'ADD' ? 'BUY' : 'SELL';
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
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: TWColors.textTertiary,
                  ),
                ],
              ),
            ),
          ),
          // Drag-to-sell bar for held positions: pick how many shares to sell
          // (0 -> all sellable) then hit Sell. Buy is one tap away too.
          if (canSell > 0) ...[
            const SizedBox(height: TWSpace.sm),
            _RebalanceSellSlider(
              key: Key('moomoo_reb_slider_${a.symbol}'),
              symbol: a.symbol,
              maxQty: canSell,
              lastPrice: pos?.lastPrice ?? 0,
              onSell: (qty) => _openTicket(a.symbol, 'SELL', qty),
              onBuy: () => _openTicket(a.symbol, 'BUY'),
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
            // Total unrealized P/L across open positions (summed from the
            // broker's per-position values; no extra fetch).
            if (_positions.isNotEmpty) ...[
              const Divider(height: TWSpace.lg, color: TWColors.hairline),
              _kvPL('Unrealized P/L', _totalPlVal, _totalPlRatio, a.currency),
            ],
          ],
        ],
      ),
    );
  }

  Widget _positionsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: TWSpace.xs, bottom: TWSpace.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Positions (${_positions.length})',
                  style: TWType.overline,
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
    final expanded = _sellExpanded == p.symbol;
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
                const SizedBox(width: TWSpace.sm),
                // Sell expands an inline quantity slider (held shares); tapping
                // again collapses it. Positions with nothing sellable just open
                // the order ticket directly.
                IconButton(
                  key: Key('moomoo_pos_sell_${p.symbol}'),
                  icon: Icon(
                    expanded ? Icons.expand_less : Icons.sell_outlined,
                    size: 18,
                  ),
                  tooltip: 'Sell',
                  onPressed: canSell > 0
                      ? () => setState(
                          () => _sellExpanded = expanded ? null : p.symbol)
                      : () => _openTicket(p.symbol, 'SELL'),
                ),
              ],
            ),
            // Inline drag-to-sell bar showing how many shares are held: drag to
            // choose the quantity (defaults to the full sellable amount) then
            // hit Sell to open the order ticket prefilled with that quantity.
            if (expanded && canSell > 0) ...[
              const SizedBox(height: TWSpace.sm),
              _RebalanceSellSlider(
                key: Key('moomoo_pos_slider_${p.symbol}'),
                symbol: p.symbol,
                maxQty: canSell,
                lastPrice: p.lastPrice,
                onSell: (qty) => _openTicket(p.symbol, 'SELL', qty),
                onBuy: () => _openTicket(p.symbol, 'BUY'),
              ),
            ],
          ],
        ),
      ),
    );
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

/// Inline "drag to sell" bar for a Rebalancing AI action that maps to a held
/// position. Drag the slider left -> right to choose how many shares to sell
/// (0 up to the full sellable quantity), then tap Sell to open the prefilled
/// order ticket. A Buy shortcut sits alongside it.
class _RebalanceSellSlider extends StatefulWidget {
  const _RebalanceSellSlider({
    super.key,
    required this.symbol,
    required this.maxQty,
    required this.lastPrice,
    required this.onSell,
    required this.onBuy,
  });

  final String symbol;
  final double maxQty;
  final double lastPrice;
  final void Function(double qty) onSell;
  final VoidCallback onBuy;

  @override
  State<_RebalanceSellSlider> createState() => _RebalanceSellSliderState();
}

class _RebalanceSellSliderState extends State<_RebalanceSellSlider> {
  // Start at the full sellable quantity so a single tap on Sell exits the
  // position; dragging left reduces it.
  late double _qty = widget.maxQty;

  @override
  void didUpdateWidget(_RebalanceSellSlider old) {
    super.didUpdateWidget(old);
    // Keep the chosen quantity within a refreshed sellable amount.
    if (widget.maxQty != old.maxQty) {
      _qty = _qty.clamp(0, widget.maxQty);
      if (_qty == 0) _qty = widget.maxQty;
    }
  }

  // Whole-share positions get integer steps; fractional holdings keep 4-dp
  // granularity so the slider can still represent them.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Sell', style: TWType.caption.copyWith(color: TWColors.down)),
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
            activeTrackColor: TWColors.down,
            inactiveTrackColor: TWColors.hairlineTop,
            thumbColor: TWColors.down,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            key: Key('moomoo_reb_sell_range_${widget.symbol}'),
            value: qty.toDouble(),
            max: widget.maxQty,
            divisions: _wholeOnly && widget.maxQty <= 100
                ? widget.maxQty.round().clamp(1, 100)
                : 100,
            onChanged: (v) => setState(() => _qty = v),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: Key('moomoo_reb_buy_btn_${widget.symbol}'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: TWColors.up,
                  side: const BorderSide(color: TWColors.up),
                  padding: const EdgeInsets.symmetric(vertical: TWSpace.sm),
                ),
                onPressed: widget.onBuy,
                child: const Text('Buy', style: TWType.label),
              ),
            ),
            const SizedBox(width: TWSpace.sm),
            Expanded(
              child: FilledButton(
                key: Key('moomoo_reb_sell_btn_${widget.symbol}'),
                style: FilledButton.styleFrom(
                  backgroundColor: TWColors.down,
                  padding: const EdgeInsets.symmetric(vertical: TWSpace.sm),
                ),
                onPressed: qty > 0 ? () => widget.onSell(qty) : null,
                child: const Text('Sell', style: TWType.label),
              ),
            ),
          ],
        ),
      ],
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
