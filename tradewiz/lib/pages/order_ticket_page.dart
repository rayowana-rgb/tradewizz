import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import '../models/broker.dart';
import '../models/market.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../theme.dart';

/// Manual order ticket: quantity/type/price -> preview -> confirm -> place.
///
/// Safety: this NEVER auto-submits. The user must explicitly preview, then
/// confirm, then place. Every place uses the server-issued confirmation token.
class OrderTicketPage extends StatefulWidget {
  const OrderTicketPage({
    super.key,
    required this.symbol,
    required this.market,
    required this.side,
    required this.repository,
  });

  final String symbol;
  final Market market;
  final OrderSide side;
  final StockRepository repository;

  @override
  State<OrderTicketPage> createState() => _OrderTicketPageState();
}

enum _Stage { form, preview, result }

class _OrderTicketPageState extends State<OrderTicketPage> {
  final _formKey = GlobalKey<FormState>();
  final _qtyController = TextEditingController();
  final _priceController = TextEditingController();

  OrderTypeKind _orderType = OrderTypeKind.limit;
  _Stage _stage = _Stage.form;
  bool _busy = false;
  String? _error;
  OrderPreview? _preview;
  OrderResult? _result;

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
      setState(() => _error = 'Please sign in to place orders.');
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
    // Log the request payload before submission (diagnostics).
    developer.log(
      'IBKR preview -> symbol=${widget.symbol} market=${widget.market.code} '
      'side=${widget.side.wire} qty=$qty type=${_orderType.wire} '
      'price=$price',
      name: 'tradewizz.order',
    );
    try {
      final pv = await widget.repository.previewOrder(
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
      setState(() => _error = 'Please sign in to place orders.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Log the request payload before submission (diagnostics).
    developer.log(
      'IBKR place -> symbol=${widget.symbol} market=${widget.market.code} '
      'side=${widget.side.wire} qty=${pv.quantity} type=${pv.orderType.wire} '
      'price=${pv.price} token=${pv.confirmationToken.isNotEmpty}',
      name: 'tradewizz.order',
    );
    try {
      final res = await widget.repository.placeOrder(
        token: token,
        symbol: widget.symbol,
        market: widget.market,
        side: widget.side,
        quantity: pv.quantity,
        orderType: pv.orderType,
        price: pv.price,
        confirmationToken: pv.confirmationToken,
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
            if (_error != null) _errorCard(_error!),
            if (_stage == _Stage.form) _buildForm(sideColor),
            if (_stage == _Stage.preview) _buildPreview(sideColor),
            if (_stage == _Stage.result) _buildResult(),
          ],
        ),
      ),
    );
  }

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
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('qty_field'),
                controller: _qtyController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Quantity',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final q = double.tryParse(v?.trim() ?? '');
                  if (q == null || q <= 0) return 'Enter a positive quantity';
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
                      value: OrderTypeKind.limit, child: Text('Limit')),
                  DropdownMenuItem(
                      value: OrderTypeKind.market, child: Text('Market')),
                ],
                onChanged: (t) =>
                    setState(() => _orderType = t ?? OrderTypeKind.limit),
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
                      : const Text('Preview order'),
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
                Row(children: [
                  const Text('Order Preview',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 17)),
                  const Spacer(),
                  _envChip(pv.tradingEnv, pv.isReal),
                ]),
                const SizedBox(height: 12),
                row('Symbol', '${pv.symbol} (${pv.moomooCode})'),
                row('Side', pv.side.label),
                row('Quantity', pv.quantity.toStringAsFixed(0)),
                row('Type', pv.orderType.label),
                if (pv.price != null) row('Price', pv.price!.toStringAsFixed(2)),
                row('Est. value',
                    '${pv.currency} ${pv.estimatedValue.toStringAsFixed(2)}'),
                if (pv.warnings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final w in pv.warnings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        const Icon(Icons.warning_amber_rounded,
                            size: 16, color: Colors.orange),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(w,
                                style: const TextStyle(
                                    color: Colors.orange, fontSize: 12))),
                      ]),
                    ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : () => setState(() => _stage = _Stage.form),
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
                  : Text('Confirm & ${pv.side.label}'),
            ),
          ),
        ]),
      ],
    );
  }

  Widget _buildResult() {
    final r = _result!;
    final ok = r.status.toUpperCase() != 'REJECTED';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Icon(ok ? Icons.check_circle : Icons.cancel,
              size: 48, color: ok ? AppColors.up : AppColors.down),
          const SizedBox(height: 12),
          Text(
            ok ? 'Order ${r.status}' : 'Order rejected',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          const SizedBox(height: 6),
          Text('${r.side.label} ${r.quantity.toStringAsFixed(0)} ${r.symbol}'),
          const SizedBox(height: 4),
          Text('Order ID: ${r.orderId}',
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 6),
          _envChip(r.tradingEnv, r.isReal),
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

  Widget _envChip(String env, bool isReal) {
    final color = isReal ? AppColors.down : AppColors.up;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isReal ? 'REAL' : 'PAPER',
        style: TextStyle(
            color: color, fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }
}
