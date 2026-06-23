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

  /// Whether the positions list is collapsed. Persisted across launches via
  /// SharedPreferences (key [_kHidePositionsPref]).
  static const String _kHidePositionsPref = 'tradewizz.moomoo.hidePositions';
  static const String _kHideManagerPref = 'tradewizz.moomoo.hideManager';
  static const String _kHideHealthPref = 'tradewizz.moomoo.hideHealth';
  static const String _kHideRebalancePref = 'tradewizz.moomoo.hideRebalance';
  bool _hidePositions = false;
  bool _hideManager = false;
  bool _hideHealth = false;
  bool _hideRebalance = false;

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
    });
  }

  Future<void> _toggleHidePositions() async {
    final next = !_hidePositions;
    setState(() => _hidePositions = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHidePositionsPref, next);
  }

  Future<void> _toggleHide(String key, bool current, void Function(bool) set) async {
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
      final acct = await widget.repository
          .moomooAccount(token: token, secret: secret);
      final pos = await widget.repository
          .moomooPositions(token: token, secret: secret);
      if (!mounted) return;
      setState(() {
        _account = acct;
        _positions = pos;
        _loading = false;
      });
      // Advisory analytics (Manager / Health / Rebalance) are fetched without
      // blocking; a failure must never clear the account / positions view.
      try {
        final mgr = await widget.repository
            .moomooManager(token: token, secret: secret);
        if (mounted) setState(() => _manager = mgr);
      } catch (_) {/* keep account + positions */}
      try {
        final h = await widget.repository
            .moomooHealth(token: token, secret: secret);
        if (mounted) setState(() => _health = h);
      } catch (_) {/* keep account + positions */}
      try {
        final rb = await widget.repository
            .moomooRebalance(token: token, secret: secret);
        if (mounted) setState(() => _rebalance = rb);
      } catch (_) {/* keep account + positions */}
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
    final controller =
        TextEditingController(text: widget.secretStore.secret ?? '');
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
              child: const Text('Clear',
                  style: TextStyle(color: TWColors.down)),
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

  Future<void> _openTicket([String? prefillSymbol]) async {
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
                TWSpace.lg, TWSpace.lg, TWSpace.lg, TWSpace.xxxxl),
            children: [
              _liveBanner(),
              const SizedBox(height: TWSpace.lg),
              if (!hasSecret)
                _setupCard()
              else ...[
                if (_error != null) _errorCard(_error!),
                _accountCard(),
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
          const Icon(Icons.warning_amber_rounded,
              color: TWColors.down, size: 20),
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
        Text(value.toStringAsFixed(0),
            style: TWType.title3.copyWith(color: TWColors.textPrimary)),
        const SizedBox(height: 2),
        Text(label,
            textAlign: TextAlign.center,
            style: TWType.overline.copyWith(color: TWColors.textTertiary)),
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
            horizontal: TWSpace.sm, vertical: TWSpace.xs),
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
            Text(hidden ? 'Show' : 'Hide',
                style: TWType.overline.copyWith(color: TWColors.textTertiary)),
          ],
        ),
      ),
    );
  }

  Widget _managerSection(MoomooLiveManagerReport m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: TWSpace.xs, bottom: TWSpace.xs),
          child: Row(
            children: [
              const Expanded(
                  child: Text('PORTFOLIO MANAGER', style: TWType.overline)),
              _toggleChip(
                const Key('moomoo_toggle_manager'),
                _hideManager,
                () => _toggleHide(_kHideManagerPref, _hideManager,
                    (v) => _hideManager = v),
              ),
            ],
          ),
        ),
        if (_hideManager)
          _card(child: Text('Portfolio Manager hidden.', style: TWType.caption))
        else
          _managerCard(m),
      ],
    );
  }

  Widget _healthSection(PortfolioHealth h) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: TWSpace.xs, bottom: TWSpace.xs),
          child: Row(
            children: [
              const Expanded(
                  child: Text('PORTFOLIO HEALTH', style: TWType.overline)),
              _toggleChip(
                const Key('moomoo_toggle_health'),
                _hideHealth,
                () => _toggleHide(
                    _kHideHealthPref, _hideHealth, (v) => _hideHealth = v),
              ),
            ],
          ),
        ),
        if (_hideHealth)
          _card(child: Text('Portfolio Health hidden.', style: TWType.caption))
        else
          _healthCard(h),
      ],
    );
  }

  Widget _rebalanceSection(RebalanceReport r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: TWSpace.xs, bottom: TWSpace.xs),
          child: Row(
            children: [
              const Expanded(
                  child: Text('REBALANCING AI', style: TWType.overline)),
              _toggleChip(
                const Key('moomoo_toggle_rebalance'),
                _hideRebalance,
                () => _toggleHide(_kHideRebalancePref, _hideRebalance,
                    (v) => _hideRebalance = v),
              ),
            ],
          ),
        ),
        if (_hideRebalance)
          _card(child: Text('Rebalancing AI hidden.', style: TWType.caption))
        else
          _rebalanceCard(r),
      ],
    );
  }

  Color _healthColor(double score) {
    if (score >= 75) return TWColors.up;
    if (score >= 50) return TWColors.warn;
    return TWColors.down;
  }

  Widget _healthCard(PortfolioHealth h) {
    final c = _healthColor(h.healthScore);
    return _card(
      key: const Key('moomoo_health_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.favorite_outline,
                  color: TWColors.accent, size: 20),
              const SizedBox(width: TWSpace.sm),
              const Expanded(
                  child: Text('Health score', style: TWType.title3)),
              Text(h.healthScore.toStringAsFixed(0),
                  style: TWType.title3.copyWith(color: c)),
              const SizedBox(width: TWSpace.xs),
              Text('/100',
                  style:
                      TWType.caption.copyWith(color: TWColors.textTertiary)),
            ],
          ),
          if (h.rating.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(h.rating,
                  style: TWType.caption.copyWith(color: c)),
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
          for (final w in h.exitWarnings) _healthLine(w, TWColors.down),
          for (final w in h.warnings) _healthLine(w, TWColors.warn),
          for (final s in h.strengths) _healthLine(s, TWColors.up),
        ],
      ),
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

  Widget _rebalanceCard(RebalanceReport r) {
    // Only show actions for symbols still held (client-side safety net).
    final held = _positions.map((p) => '${p.symbol}@US').toSet();
    final report = r.reconciledWith(held);
    final acted =
        report.actions.where((a) => a.action != 'HOLD').toList();
    return _card(
      key: const Key('moomoo_rebalance_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune, color: TWColors.accent, size: 20),
              const SizedBox(width: TWSpace.sm),
              const Expanded(
                  child: Text('Rebalancing AI', style: TWType.title3)),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: TWSpace.sm, vertical: 3),
                decoration: BoxDecoration(
                  color: TWColors.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(TWRadius.chip),
                ),
                child: Text(report.profile,
                    style: TWType.overline
                        .copyWith(color: TWColors.accentBright)),
              ),
            ],
          ),
          if (report.summary.isNotEmpty) ...[
            const SizedBox(height: TWSpace.sm),
            Text(report.summary, style: TWType.caption),
          ],
          const SizedBox(height: TWSpace.md),
          if (acted.isEmpty)
            Text('No rebalancing actions — portfolio looks balanced.',
                style: TWType.caption)
          else
            ...acted.map(_rebalanceTile),
          for (final w in report.warnings) _healthLine(w, TWColors.warn),
        ],
      ),
    );
  }

  Widget _rebalanceTile(RebalanceAction a) {
    final color = _actionColor(a.action);
    return Padding(
      key: Key('moomoo_reb_${a.symbol}'),
      padding: const EdgeInsets.only(bottom: TWSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: TWSpace.sm, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(TWRadius.chip),
            ),
            child: Text(a.action,
                style: TWType.overline.copyWith(color: color)),
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
                if (a.reason.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(a.reason, style: TWType.caption),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _managerCard(MoomooLiveManagerReport m) {
    final riskColor = _riskColor(m.riskLevel);
    return _card(
      key: const Key('moomoo_manager_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.smart_toy_outlined,
                  color: TWColors.accent, size: 20),
              const SizedBox(width: TWSpace.sm),
              const Expanded(
                child: Text('Portfolio Manager', style: TWType.title3),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: TWSpace.sm, vertical: 3),
                decoration: BoxDecoration(
                  color: riskColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(TWRadius.chip),
                ),
                child: Text('${m.riskLevel} risk',
                    style: TWType.overline.copyWith(color: riskColor)),
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
          if (m.recommendations.isNotEmpty) ...[
            const Divider(height: TWSpace.lg, color: TWColors.hairline),
            ...m.recommendations.map(_recTile),
          ],
        ],
      ),
    );
  }

  Widget _recTile(MoomooLiveManagerRec r) {
    final color = _sevColor(r.severity);
    return Padding(
      key: Key('moomoo_rec_${r.kind}'),
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
                    child: CircularProgressIndicator(strokeWidth: 2)),
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
                child: Text('Positions (${_positions.length})',
                    style: TWType.overline),
              ),
              InkWell(
                key: const Key('moomoo_toggle_positions'),
                onTap: _toggleHidePositions,
                borderRadius: BorderRadius.circular(TWRadius.chip),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: TWSpace.sm, vertical: TWSpace.xs),
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
                      Text(_hidePositions ? 'Show' : 'Hide',
                          style: TWType.overline
                              .copyWith(color: TWColors.textTertiary)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_hidePositions)
          _card(
            child: Text('Positions hidden.', style: TWType.caption),
          )
        else if (_positions.isEmpty)
          _card(child: Text('No open positions.', style: TWType.caption))
        else
          ..._positions.map(_positionTile),
      ],
    );
  }

  Widget _positionTile(MoomooLivePosition p) {
    final up = p.plVal >= 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: TWSpace.sm),
      child: _card(
        key: Key('moomoo_pos_${p.symbol}'),
        child: Row(
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
                    Text('Avg cost ${_money(p.costPrice, "USD")}',
                        style: TWType.caption),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${up ? '+' : '-'}${_money(p.plVal.abs(), "USD")}',
                  style: TWType.label
                      .copyWith(color: up ? TWColors.up : TWColors.down),
                ),
                const SizedBox(height: 2),
                Text(
                  '${up ? '+' : ''}${(p.plRatio * 100).toStringAsFixed(2)}%',
                  style: TWType.caption
                      .copyWith(color: up ? TWColors.up : TWColors.down),
                ),
              ],
            ),
            const SizedBox(width: TWSpace.sm),
            IconButton(
              icon: const Icon(Icons.sell_outlined, size: 18),
              tooltip: 'Sell',
              onPressed: () => _openTicket(p.symbol),
            ),
          ],
        ),
      ),
    );
  }

  /// Total unrealized P/L = sum of each position's broker-reported pl_val.
  double get _totalPlVal =>
      _positions.fold(0.0, (sum, p) => sum + p.plVal);

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
          Text('$amount$pct',
              style: TWType.tabular(TWType.label).copyWith(color: color)),
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
  });

  final StockRepository repository;
  final String token;
  final String secret;
  final String? prefillSymbol;

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
      _side = 'SELL';
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
      setState(() => _error =
          'Fractional quantities are only allowed for MARKET orders.');
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
        _segmented(['BUY', 'SELL'], _side, (v) => setState(() => _side = v),
            key: const Key('moomoo_side_seg')),
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
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
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
        _segmented(['MARKET', 'LIMIT'], _orderType,
            (v) => setState(() => _orderType = v),
            key: const Key('moomoo_type_seg')),
        if (_orderType == 'LIMIT') ...[
          const SizedBox(height: TWSpace.md),
          TextField(
            key: const Key('moomoo_price_field'),
            controller: _priceCtl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
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
                      strokeWidth: 2, color: Colors.white))
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
              const Icon(Icons.warning_amber_rounded,
                  color: TWColors.down, size: 20),
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
              'Order exceeds the per-order cap. Reduce size and try again.'),
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
                        strokeWidth: 2, color: Colors.white))
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
        const Icon(Icons.check_circle_outline,
            color: TWColors.up, size: 56),
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

  Widget _segmented(List<String> options, String value,
      ValueChanged<String> onChanged,
      {Key? key}) {
    return SegmentedButton<String>(
      key: key,
      segments: [
        for (final o in options)
          ButtonSegment(value: o, label: Text(o, style: TWType.label)),
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
              child: Text(v,
                  style: TWType.tabular(TWType.label),
                  textAlign: TextAlign.right),
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
class _DecimalQtyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
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
