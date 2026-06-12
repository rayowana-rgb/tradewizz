import 'package:flutter/material.dart';

import '../home/activation_scope.dart';
import '../models/broker_app.dart';
import '../models/market.dart';
import '../services/broker_launcher.dart';
import '../services/user_prefs_scope.dart';
import '../theme_tradewizz.dart';

/// Read-only broker hand-off entrypoint.
///
/// Presents the "Open Broker" picker (Wizard Terminal styled) for [symbol] in
/// [market]. Selecting a broker opens that broker's app (deep-linking to the
/// symbol when supported) or, if it is not installed, its Play Store page.
///
/// Play Store compliance: this NEVER executes a trade or handles funds. It only
/// opens a third-party app for the user to research/trade there themselves.
Future<void> showBrokerOpenSheet(
  BuildContext context, {
  required String symbol,
  required Market market,
  BrokerService? service,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: TWColors.sheetScrim,
    builder: (ctx) => _BrokerOpenSheet(
      symbol: symbol,
      market: market,
      service: service,
    ),
  );
}

/// A Wizard-Terminal styled "Open Broker" action button.
///
/// Drop this onto the analysis page, stock detail page, or buy/sell signal
/// cards. Tapping it opens the broker picker for [symbol] in [market].
class OpenBrokerButton extends StatelessWidget {
  const OpenBrokerButton({
    super.key,
    required this.symbol,
    required this.market,
    this.label = 'Open Broker',
    this.expand = true,
    this.service,
  });

  final String symbol;
  final Market market;
  final String label;
  final bool expand;
  final BrokerService? service;

  void _open(BuildContext context) => showBrokerOpenSheet(
        context,
        symbol: symbol,
        market: market,
        service: service,
      );

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton.icon(
      key: const Key('open_broker_button'),
      icon: const Icon(Icons.open_in_new, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: TWColors.accent,
        side: const BorderSide(color: TWColors.hairlineTop),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TWRadius.button),
        ),
      ),
      onPressed: () => _open(context),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// A compact, icon-only "Open Broker" affordance for dense signal cards.
class OpenBrokerIconButton extends StatelessWidget {
  const OpenBrokerIconButton({
    super.key,
    required this.symbol,
    required this.market,
    this.service,
  });

  final String symbol;
  final Market market;
  final BrokerService? service;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('open_broker_icon_button'),
      tooltip: 'Open Broker',
      icon: const Icon(Icons.open_in_new, size: 18, color: TWColors.accent),
      onPressed: () => showBrokerOpenSheet(
        context,
        symbol: symbol,
        market: market,
        service: service,
      ),
    );
  }
}

class _BrokerOpenSheet extends StatefulWidget {
  const _BrokerOpenSheet({
    required this.symbol,
    required this.market,
    this.service,
  });

  final String symbol;
  final Market market;
  final BrokerService? service;

  @override
  State<_BrokerOpenSheet> createState() => _BrokerOpenSheetState();
}

class _BrokerOpenSheetState extends State<_BrokerOpenSheet> {
  late final BrokerService _service = widget.service ?? _buildDefaultService();
  String? _busyBrokerId;

  BrokerService _buildDefaultService() {
    // Wire analytics into the existing activation/metrics backend sink so the
    // `broker_open_clicked` event flows through the same pipeline. Best-effort.
    final metrics = ActivationScope.maybeOf(context);
    return BrokerService(
      analytics: metrics == null
          ? null
          : (event, {required properties}) {
              final meta = properties.entries
                  .map((e) => '${e.key}=${e.value}')
                  .join(';');
              metrics.trackBrokerOpen(meta);
            },
    );
  }

  Future<void> _onPick(BrokerApp broker) async {
    if (_busyBrokerId != null) return;
    setState(() => _busyBrokerId = broker.id);
    final outcome = await _service.open(
      broker: broker,
      symbol: widget.symbol,
      market: widget.market,
    );
    if (!mounted) return;
    setState(() => _busyBrokerId = null);
    Navigator.of(context).pop();
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (outcome == BrokerOpenOutcome.openedStore) {
      messenger?.showSnackBar(SnackBar(
        content: Text('${broker.label} is not installed — opening the Play Store.'),
      ));
    } else if (outcome == BrokerOpenOutcome.failed) {
      messenger?.showSnackBar(SnackBar(
        content: Text('Could not open ${broker.label}.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferredId =
        UserPrefsScope.maybeOf(context)?.prefs.preferredBrokerId;
    // Show the preferred broker first.
    final brokers = [...BrokerApp.values]..sort((a, b) {
        if (a.id == preferredId) return -1;
        if (b.id == preferredId) return 1;
        return 0;
      });

    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: TWColors.bgRaised,
          borderRadius: BorderRadius.vertical(top: Radius.circular(TWRadius.cardLg)),
          border: Border(top: BorderSide(color: TWColors.hairlineTop)),
        ),
        padding: const EdgeInsets.fromLTRB(
            TWSpace.lg, TWSpace.md, TWSpace.lg, TWSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: TWSpace.lg),
                decoration: BoxDecoration(
                  color: TWColors.hairlineTop,
                  borderRadius: BorderRadius.circular(TWRadius.chip),
                ),
              ),
            ),
            Row(
              children: [
                const Icon(Icons.open_in_new, color: TWColors.accent, size: 20),
                const SizedBox(width: TWSpace.sm),
                Expanded(
                  child: Text('Open in broker', style: TWType.title3),
                ),
              ],
            ),
            const SizedBox(height: TWSpace.xs),
            Text(
              '${widget.symbol.toUpperCase()} · ${widget.market.code} — '
              'opens your broker app for research & trading. '
              'TradeWizz never places orders.',
              style: TWType.caption,
            ),
            const SizedBox(height: TWSpace.lg),
            for (final broker in brokers) ...[
              _BrokerRow(
                broker: broker,
                preferred: broker.id == preferredId,
                busy: _busyBrokerId == broker.id,
                disabled: _busyBrokerId != null && _busyBrokerId != broker.id,
                onTap: () => _onPick(broker),
              ),
              const SizedBox(height: TWSpace.sm),
            ],
          ],
        ),
      ),
    );
  }
}

class _BrokerRow extends StatelessWidget {
  const _BrokerRow({
    required this.broker,
    required this.preferred,
    required this.busy,
    required this.disabled,
    required this.onTap,
  });

  final BrokerApp broker;
  final bool preferred;
  final bool busy;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: Material(
        color: TWColors.surfaceCard,
        borderRadius: BorderRadius.circular(TWRadius.card),
        child: InkWell(
          key: Key('broker_pick_${broker.id}'),
          borderRadius: BorderRadius.circular(TWRadius.card),
          onTap: disabled || busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: TWSpace.lg, vertical: TWSpace.md),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: TWColors.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(TWRadius.sm),
                  ),
                  child: const Icon(Icons.account_balance_wallet_outlined,
                      color: TWColors.accent, size: 18),
                ),
                const SizedBox(width: TWSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(broker.label, style: TWType.label),
                      Text(
                        broker.supportsSymbolDeepLink
                            ? 'Deep links to the symbol'
                            : 'Opens the app',
                        style: TWType.caption,
                      ),
                    ],
                  ),
                ),
                if (preferred)
                  Container(
                    margin: const EdgeInsets.only(right: TWSpace.sm),
                    padding: const EdgeInsets.symmetric(
                        horizontal: TWSpace.sm, vertical: 2),
                    decoration: BoxDecoration(
                      color: TWColors.accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(TWRadius.chip),
                    ),
                    child: Text('Preferred',
                        style: TWType.overline
                            .copyWith(color: TWColors.accentBright)),
                  ),
                if (busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.chevron_right, color: TWColors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
