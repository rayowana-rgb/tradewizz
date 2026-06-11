import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import '../models/broker.dart';
import '../models/market.dart';
import '../models/simulation.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../theme.dart';

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

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuantity ?? widget.maxQuantity;
    if (initial != null && initial > 0) {
      _qtyController.text = initial.toStringAsFixed(0);
    }
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
              TextFormField(
                key: const Key('qty_field'),
                controller: _qtyController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Quantity',
                  helperText: widget.maxQuantity != null
                      ? 'You hold ${widget.maxQuantity!.toStringAsFixed(0)} '
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
                row('Price', pv.price.toStringAsFixed(2)),
                row('Est. value',
                    '${pv.currency} ${pv.estimatedValue.toStringAsFixed(2)}'),
                row('Cash after', pv.cashAfter.toStringAsFixed(2)),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          const Icon(Icons.check_circle, size: 48, color: AppColors.up),
          const SizedBox(height: 12),
          const Text(
            'Simulated order filled',
            key: Key('sim_result_title'),
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
          ),
          const SizedBox(height: 6),
          Text('${r.side} ${r.quantity.toStringAsFixed(0)} ${r.symbol} '
              '@ ${r.price.toStringAsFixed(2)}'),
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
