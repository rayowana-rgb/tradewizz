import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import '../models/broker.dart';
import '../models/market.dart';
import '../models/simulation.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../theme.dart';
import 'account_page.dart' show formatSimMoney;

/// Base accounting currency for the simulated cash ledger (see backend
/// SimulationService.BASE_CURRENCY). Cash / buying power are held in this
/// currency even when the order itself is priced in a foreign currency.
const String _simBaseCurrency = 'USD';

/// Manual SIMULATED order ticket: quantity/type/price -> preview -> place.
///
/// Pure paper trading. This NEVER contacts a broker and NEVER places a real
/// order. The user previews, then confirms a simulated fill. Every stage shows
/// a clear "simulation only" banner.
class OrderTicketPage extends StatefulWidget {
  const OrderTicketPage({
    super.key,
    required this.symbol,
    required this.market,
    required this.side,
    required this.repository,
    this.initialQuantity,
    this.maxQuantity,
  });

  final String symbol;
  final Market market;
  final OrderSide side;
  final StockRepository repository;

  /// Optional quantity to prefill the ticket with (e.g. selling a full holding).
  final double? initialQuantity;

  /// Optional upper bound on quantity (e.g. you cannot sell more than you hold
  /// in the simulation). When set, the quantity field is validated against it.
  final double? maxQuantity;

  @override
  State<OrderTicketPage> createState() => _OrderTicketPageState();
}

enum _Stage { form, preview, result }

class _OrderTicketPageState extends State<OrderTicketPage> {
  final _formKey = GlobalKey<FormState>();
  final _qtyController = TextEditingController();
  final _priceController = TextEditingController();

  OrderTypeKind _orderType = OrderTypeKind.market;
  _Stage _stage = _Stage.form;
  bool _busy = false;
  String? _error;
  SimOrderPreview? _preview;
  SimOrderResult? _result;

  /// Whether this ticket is selling a known holding (we then know the max and
  /// can show the holdings summary + a drag-to-set-amount slider).
  bool get _isSellWithHolding =>
      widget.side == OrderSide.sell &&
      (widget.maxQuantity ?? 0) > 0;

  /// Shares per lot for the market. IDX trades in lots of 100 shares; the other
  /// supported markets are effectively 1 share per "lot" for our purposes.
  int get _sharesPerLot => widget.market.code == 'IDX' ? 100 : 1;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuantity ?? widget.maxQuantity;
    if (initial != null && initial > 0) {
      _qtyController.text = initial.toStringAsFixed(0);
    }
  }

  /// Current quantity parsed from the text field (0 when empty/invalid).
  double get _currentQty {
    final q = double.tryParse(_qtyController.text.trim());
    return (q == null || q < 0) ? 0 : q;
  }

  /// Set the quantity from the slider / quick-pick chips. Snaps to whole lots
  /// for IDX and clamps to the holding, keeping the text field in sync.
  void _setQty(double value) {
    final max = widget.maxQuantity ?? value;
    var q = value.clamp(0, max).toDouble();
    final lot = _sharesPerLot;
    if (lot > 1) {
      // Snap to a whole number of lots, but never exceed what is held.
      q = (q / lot).round() * lot.toDouble();
      if (q > max) q = (max / lot).floor() * lot.toDouble();
    } else {
      q = q.roundToDouble();
    }
    setState(() => _qtyController.text = q.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  Future<void> _doPreview() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final token = AuthScope.read(context).token;
    if (token == null) {
      setState(() => _error = 'Please sign in to use the simulation portfolio.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final qty = double.parse(_qtyController.text.trim());
    final price = _orderType == OrderTypeKind.limit
        ? double.parse(_priceController.text.trim())
        : null;
    developer.log(
      'SIM preview -> symbol=${widget.symbol} market=${widget.market.code} '
      'side=${widget.side.wire} qty=$qty type=${_orderType.wire} price=$price',
      name: 'tradewizz.sim_order',
    );
    try {
      final pv = await widget.repository.simPreviewOrder(
        token: token,
        symbol: widget.symbol,
        market: widget.market,
        side: widget.side,
        quantity: qty,
        orderType: _orderType,
        price: price,
      );
      if (!mounted) return;
      setState(() {
        _preview = pv;
        _stage = _Stage.preview;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not preview order. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doPlace() async {
    final pv = _preview;
    if (pv == null) return;
    final token = AuthScope.read(context).token;
    if (token == null) {
      setState(() => _error = 'Please sign in to use the simulation portfolio.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    developer.log(
      'SIM place -> symbol=${widget.symbol} market=${widget.market.code} '
      'side=${widget.side.wire} qty=${pv.quantity} type=${pv.orderType} '
      'price=${pv.price}',
      name: 'tradewizz.sim_order',
    );
    try {
      final res = await widget.repository.simPlaceOrder(
        token: token,
        symbol: widget.symbol,
        market: widget.market,
        side: widget.side,
        quantity: pv.quantity,
        orderType: _orderType,
        price: _orderType == OrderTypeKind.limit ? pv.price : null,
      );
      if (!mounted) return;
      setState(() {
        _result = res;
        _stage = _Stage.result;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not place order. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sideColor =
        widget.side == OrderSide.buy ? AppColors.up : AppColors.down;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.side.label} ${widget.symbol}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            _simulationBanner(),
            const SizedBox(height: 12),
            if (_error != null) _errorCard(_error!),
            if (_stage == _Stage.form) _buildForm(sideColor),
            if (_stage == _Stage.preview) _buildPreview(sideColor),
            if (_stage == _Stage.result) _buildResult(),
          ],
        ),
      ),
    );
  }

  Widget _simulationBanner() => Container(
        key: const Key('sim_warning_banner'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
        ),
        child: Row(children: const [
          Icon(Icons.science_outlined, color: Colors.orange, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Simulation mode only. This does not place a real trade.',
              style: TextStyle(
                  color: Colors.orange, fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
        ]),
      );

  Widget _errorCard(String msg) => Card(
        color: AppColors.down.withValues(alpha: 0.06),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Icon(Icons.error_outline, color: AppColors.down),
            const SizedBox(width: 12),
            Expanded(child: Text(msg)),
          ]),
        ),
      );

  Widget _buildForm(Color sideColor) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.side.label} ${widget.symbol} · ${widget.market.code}',
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              const SizedBox(height: 16),
              if (_isSellWithHolding) ...[
                _holdingSummary(),
                const SizedBox(height: 12),
                _quantitySlider(sideColor),
                const SizedBox(height: 12),
              ],
              TextFormField(
                key: const Key('qty_field'),
                controller: _qtyController,
                keyboardType: TextInputType.number,
                // Keep the slider / chips in sync while the user types.
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _sharesPerLot > 1
                      ? 'Quantity (shares)'
                      : 'Quantity',
                  helperText: widget.maxQuantity != null
                      ? 'You hold ${_sharesLotsLabel(widget.maxQuantity!)} '
                          '(simulated)'
                      : null,
                  border: const OutlineInputBorder(),
                ),
                validator: (v) {
                  final q = double.tryParse(v?.trim() ?? '');
                  if (q == null || q <= 0) return 'Enter a positive quantity';
                  final max = widget.maxQuantity;
                  if (max != null && q > max) {
                    return 'You only hold ${max.toStringAsFixed(0)} (simulated)';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<OrderTypeKind>(
                initialValue: _orderType,
                decoration: const InputDecoration(
                  labelText: 'Order type',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                      value: OrderTypeKind.market, child: Text('Market')),
                  DropdownMenuItem(
                      value: OrderTypeKind.limit, child: Text('Limit')),
                ],
                onChanged: (t) =>
                    setState(() => _orderType = t ?? OrderTypeKind.market),
              ),
              if (_orderType == OrderTypeKind.limit) ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('price_field'),
                  controller: _priceController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Limit price',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    if (_orderType != OrderTypeKind.limit) return null;
                    final p = double.tryParse(v?.trim() ?? '');
                    if (p == null || p <= 0) return 'Enter a positive price';
                    return null;
                  },
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('preview_order_button'),
                  onPressed: _busy ? null : _doPreview,
                  style: FilledButton.styleFrom(
                    backgroundColor: sideColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Preview simulated order'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "1,200 shares (12 lots)" for IDX, or just "10 shares" elsewhere.
  String _sharesLotsLabel(double shares) {
    final s = shares.toStringAsFixed(0);
    if (_sharesPerLot > 1) {
      final lots = (shares / _sharesPerLot).floor();
      return '$s shares ($lots lot${lots == 1 ? '' : 's'})';
    }
    return '$s share${shares == 1 ? '' : 's'}';
  }

  /// Big readout of what is currently held, so the user sees their position
  /// before deciding how much to sell.
  Widget _holdingSummary() {
    final max = widget.maxQuantity!;
    return Container(
      key: const Key('sell_holding_summary'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.down.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.down.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        const Icon(Icons.account_balance_wallet_outlined,
            size: 18, color: AppColors.down),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('You currently hold',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 2),
              Text(
                _sharesLotsLabel(max),
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 16),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  /// Drag-from-left-to-right slider (plus quick-pick chips) to choose how many
  /// shares/lots to sell, from 0 up to the full holding.
  Widget _quantitySlider(Color sideColor) {
    final max = widget.maxQuantity!;
    final qty = _currentQty.clamp(0, max).toDouble();
    final lot = _sharesPerLot;
    // Slider divisions snap to whole lots (or whole shares when lot == 1).
    final steps = lot > 1 ? (max / lot).floor() : max.floor();
    final divisions = steps > 0 ? steps : null;

    Widget chip(String label, double value) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            label: Text(label),
            visualDensity: VisualDensity.compact,
            onPressed: () => _setQty(value),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Amount to sell',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          const Spacer(),
          Text(
            _sharesLotsLabel(qty),
            key: const Key('sell_slider_value'),
            style:
                const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
        ]),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: sideColor,
            thumbColor: sideColor,
            overlayColor: sideColor.withValues(alpha: 0.15),
          ),
          child: Slider(
            key: const Key('sell_qty_slider'),
            value: qty,
            min: 0,
            max: max,
            divisions: divisions,
            label: _sharesLotsLabel(qty),
            onChanged: (v) => _setQty(v),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            chip('25%', max * 0.25),
            chip('50%', max * 0.5),
            chip('75%', max * 0.75),
            chip('Max', max),
          ]),
        ),
      ],
    );
  }

  Widget _buildPreview(Color sideColor) {
    final pv = _preview!;
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(
                child: Text(k, style: const TextStyle(color: Colors.grey))),
            Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: const [
                  Text('Simulated Order Preview',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                  Spacer(),
                  _SimChip(),
                ]),
                const SizedBox(height: 12),
                row('Symbol', '${pv.symbol} · ${pv.market.code}'),
                row('Side', pv.side),
                row('Quantity', pv.quantity.toStringAsFixed(0)),
                row('Type', pv.orderType),
                row('Price', formatSimMoney(pv.price, pv.currency)),
                row('Est. value',
                    formatSimMoney(pv.estimatedValue, pv.currency)),
                row('Cash after',
                    formatSimMoney(pv.cashAfter, _simBaseCurrency)),
                const SizedBox(height: 12),
                Row(children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(pv.warning,
                          key: const Key('sim_preview_warning'),
                          style: const TextStyle(
                              color: Colors.orange, fontSize: 12))),
                ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed:
                  _busy ? null : () => setState(() => _stage = _Stage.form),
              child: const Text('Back'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              key: const Key('confirm_place_button'),
              onPressed: _busy ? null : _doPlace,
              style: FilledButton.styleFrom(
                backgroundColor: sideColor,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text('Confirm (simulated ${pv.side})'),
            ),
          ),
        ]),
      ],
    );
  }

  Widget _buildResult() {
    final r = _result!;
    final pending = r.pending;
    final priceLine = (pending && r.price <= 0)
        ? '${r.side} ${r.quantity.toStringAsFixed(0)} ${r.symbol}'
        : '${r.side} ${r.quantity.toStringAsFixed(0)} ${r.symbol} '
            '${pending ? '~' : '@'} '
            '${formatSimMoney(r.price, r.market.currency)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Icon(pending ? Icons.schedule : Icons.check_circle,
              size: 48, color: pending ? Colors.orange : AppColors.up),
          const SizedBox(height: 12),
          Text(
            pending
                ? 'Simulated order queued'
                : 'Simulated order filled',
            key: const Key('sim_result_title'),
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
          ),
          const SizedBox(height: 6),
          Text(priceLine),
          const SizedBox(height: 4),
          Text('Order ID: ${r.orderId}',
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 6),
          const _SimChip(),
          const SizedBox(height: 8),
          Text(r.message,
              key: const Key('sim_result_message'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.orange, fontSize: 12)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(r),
              child: const Text('Done'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _SimChip extends StatelessWidget {
  const _SimChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Text(
        'SIMULATED',
        style: TextStyle(
            color: Colors.orange, fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }
}
