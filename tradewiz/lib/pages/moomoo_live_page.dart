import 'package:flutter/material.dart';

import '../models/moomoo_live.dart';
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

  String? get _token => AuthScope.read(context).token;

  @override
  void initState() {
    super.initState();
    widget.secretStore.load().then((_) {
      if (mounted && widget.secretStore.hasSecret) _refresh();
      if (mounted) setState(() {});
    });
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
          padding: const EdgeInsets.only(left: TWSpace.xs, bottom: TWSpace.sm),
          child: Text('Positions (${_positions.length})',
              style: TWType.overline),
        ),
        if (_positions.isEmpty)
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
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${up ? '+' : ''}${_money(p.plVal, "USD")}',
                  style: TWType.label
                      .copyWith(color: up ? TWColors.up : TWColors.down),
                ),
                const SizedBox(height: 2),
                Text('${(p.plRatio * 100).toStringAsFixed(2)}%',
                    style: TWType.caption),
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
    final qty = double.tryParse(_qtyCtl.text.trim());
    final price = double.tryParse(_priceCtl.text.trim());
    if (symbol.isEmpty) {
      setState(() => _error = 'Enter a symbol.');
      return;
    }
    if (qty == null || qty <= 0 || qty != qty.roundToDouble()) {
      setState(() => _error = 'Quantity must be a whole number of shares.');
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
          keyboardType: TextInputType.number,
          style: TWType.body,
          decoration: const InputDecoration(
            labelText: 'Quantity (whole shares)',
            border: OutlineInputBorder(),
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
