import 'package:flutter/material.dart';

import '../home/activation_scope.dart';
import '../models/broker_app.dart';
import '../models/market.dart';
import '../services/broker_launcher.dart';
import '../services/user_prefs_scope.dart';
import '../theme_tradewizz.dart';
import 'broker_logo.dart';

// ===========================================================================
// Public entrypoints
// ===========================================================================

/// Run the read-only "Open Broker" flow for [symbol] in [market].
///
/// Behaviour (enhanced UX):
///   1. emit `broker_open_clicked` (intent).
///   2. If a preferred broker is set AND installed → skip the picker, show the
///      confirmation sheet, then open the app on confirm.
///   3. Otherwise show the broker picker; the chosen broker then goes through
///      the confirmation sheet (when installed) or straight to the Play Store
///      (when not installed → `broker_store_redirect`).
///
/// Play Store compliance: TradeWizz NEVER executes trades or handles funds —
/// it only opens a third-party broker app (deep-linked to the symbol when
/// supported) or that broker's Play Store page.
Future<void> openBrokerFlow(
  BuildContext context, {
  required String symbol,
  required Market market,
  String source = 'unknown',
  bool forcePicker = false,
  BrokerService? service,
}) async {
  final svc = service ?? _defaultService(context);
  final store = UserPrefsScope.maybeOf(context);
  final preferred = BrokerApp.fromId(store?.prefs.preferredBrokerId);

  svc.trackClicked(
      broker: preferred, symbol: symbol, market: market, source: source);

  // Fast path: preferred broker is installed → skip the picker entirely.
  if (!forcePicker && preferred != null && await svc.isInstalled(preferred)) {
    if (!context.mounted) return;
    await _confirmAndOpen(context, broker: preferred, symbol: symbol,
        market: market, service: svc);
    return;
  }

  if (!context.mounted) return;
  await _showBrokerPicker(context,
      symbol: symbol, market: market, service: svc);
}

/// Show the broker picker directly (used by "Choose Broker").
Future<void> showBrokerOpenSheet(
  BuildContext context, {
  required String symbol,
  required Market market,
  BrokerService? service,
}) {
  return _showBrokerPicker(context,
      symbol: symbol, market: market, service: service ?? _defaultService(context));
}

BrokerService _defaultService(BuildContext context) {
  // Wire the three analytics events into the existing activation/metrics
  // backend sink so they flow through the same pipeline. Best-effort.
  final metrics = ActivationScope.maybeOf(context);
  return BrokerService(
    analytics: metrics == null
        ? null
        : (event, {required properties}) {
            final meta =
                properties.entries.map((e) => '${e.key}=${e.value}').join(';');
            switch (event) {
              case BrokerService.clickedEvent:
                metrics.trackBrokerOpen(meta);
              case BrokerService.confirmedEvent:
                metrics.trackBrokerOpenConfirmed(meta);
              case BrokerService.storeRedirectEvent:
                metrics.trackBrokerStoreRedirect(meta);
            }
          },
  );
}

// ===========================================================================
// Buttons
// ===========================================================================

/// A Wizard-Terminal styled "Open Broker" action button.
///
/// Tap → smart flow (skip picker when the preferred broker is installed).
/// Long-press → quick menu: Choose Broker / Change Preferred Broker.
class OpenBrokerButton extends StatelessWidget {
  const OpenBrokerButton({
    super.key,
    required this.symbol,
    required this.market,
    this.label = 'Open Broker',
    this.expand = true,
    this.source = 'analysis',
    this.service,
  });

  final String symbol;
  final Market market;
  final String label;
  final bool expand;
  final String source;
  final BrokerService? service;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onLongPress: () => _showQuickMenu(context,
          symbol: symbol, market: market, source: source, service: service),
      child: OutlinedButton.icon(
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
        onPressed: () => openBrokerFlow(context,
            symbol: symbol, market: market, source: source, service: service),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// A compact icon-only "Open Broker" affordance for dense cards (screener,
/// watchlist, portfolio holdings).
///
/// Tap → smart flow. Long-press → Choose Broker / Change Preferred Broker.
class OpenBrokerIconButton extends StatelessWidget {
  const OpenBrokerIconButton({
    super.key,
    required this.symbol,
    required this.market,
    this.source = 'card',
    this.size = 20,
    this.service,
  });

  final String symbol;
  final Market market;
  final String source;
  final double size;
  final BrokerService? service;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Open Broker',
      child: InkResponse(
        key: Key('open_broker_icon_${symbol}_${market.code}'),
        radius: size + 6,
        onTap: () => openBrokerFlow(context,
            symbol: symbol, market: market, source: source, service: service),
        onLongPress: () => _showQuickMenu(context,
            symbol: symbol, market: market, source: source, service: service),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(Icons.open_in_new, size: size, color: TWColors.accent),
        ),
      ),
    );
  }
}

// ===========================================================================
// Long-press quick menu: Choose Broker / Change Preferred Broker
// ===========================================================================

Future<void> _showQuickMenu(
  BuildContext context, {
  required String symbol,
  required Market market,
  required String source,
  BrokerService? service,
}) async {
  final svc = service ?? _defaultService(context);
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: TWColors.sheetScrim,
    builder: (ctx) => _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Grabber(),
          Text('Broker options', style: TWType.title3),
          const SizedBox(height: TWSpace.md),
          _MenuTile(
            key: const Key('quick_choose_broker'),
            icon: Icons.open_in_new,
            title: 'Choose Broker',
            subtitle: 'Pick a broker to open ${symbol.toUpperCase()}.',
            onTap: () => Navigator.of(ctx).pop('choose'),
          ),
          const SizedBox(height: TWSpace.sm),
          _MenuTile(
            key: const Key('quick_change_preferred'),
            icon: Icons.star_outline_rounded,
            title: 'Change Preferred Broker',
            subtitle: 'Set the broker used by the quick Open action.',
            onTap: () => Navigator.of(ctx).pop('preferred'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (choice == 'choose') {
    await _showBrokerPicker(context,
        symbol: symbol, market: market, service: svc);
  } else if (choice == 'preferred') {
    await showPreferredBrokerSheet(context);
  }
}

// ===========================================================================
// Broker picker
// ===========================================================================

Future<void> _showBrokerPicker(
  BuildContext context, {
  required String symbol,
  required Market market,
  required BrokerService service,
}) {
  final preferredId = UserPrefsScope.maybeOf(context)?.prefs.preferredBrokerId;
  final brokers = [...BrokerApp.values]..sort((a, b) {
      if (a.id == preferredId) return -1;
      if (b.id == preferredId) return 1;
      return 0;
    });

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: TWColors.sheetScrim,
    builder: (ctx) => _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Grabber(),
          Row(
            children: [
              const Icon(Icons.open_in_new, color: TWColors.accent, size: 20),
              const SizedBox(width: TWSpace.sm),
              Expanded(child: Text('Open in broker', style: TWType.title3)),
            ],
          ),
          const SizedBox(height: TWSpace.xs),
          Text(
            '${symbol.toUpperCase()} · ${market.code} — opens your broker app '
            'for research & trading. TradeWizz never places orders.',
            style: TWType.caption,
          ),
          const SizedBox(height: TWSpace.lg),
          for (final broker in brokers) ...[
            _BrokerRow(
              broker: broker,
              preferred: broker.id == preferredId,
              onTap: () async {
                Navigator.of(ctx).pop();
                if (!context.mounted) return;
                await _confirmAndOpen(context,
                    broker: broker,
                    symbol: symbol,
                    market: market,
                    service: service);
              },
            ),
            const SizedBox(height: TWSpace.sm),
          ],
        ],
      ),
    ),
  );
}

// ===========================================================================
// Confirmation sheet + open
// ===========================================================================

/// Show the confirmation sheet for [broker]; on confirm, open the broker (app
/// when installed, else Play Store) and surface the outcome.
Future<void> _confirmAndOpen(
  BuildContext context, {
  required BrokerApp broker,
  required String symbol,
  required Market market,
  required BrokerService service,
}) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: TWColors.sheetScrim,
    builder: (ctx) => _ConfirmationSheet(broker: broker, symbol: symbol),
  );
  if (confirmed != true || !context.mounted) return;

  final outcome = await service.open(
    broker: broker,
    symbol: symbol,
    market: market,
  );
  if (!context.mounted) return;

  final messenger = ScaffoldMessenger.maybeOf(context);
  if (outcome == BrokerOpenOutcome.openedStore) {
    messenger?.showSnackBar(SnackBar(
      content:
          Text('${broker.label} is not installed — opening the Play Store.'),
    ));
  } else if (outcome == BrokerOpenOutcome.failed) {
    messenger?.showSnackBar(
        SnackBar(content: Text('Could not open ${broker.label}.')));
  }
}

class _ConfirmationSheet extends StatelessWidget {
  const _ConfirmationSheet({required this.broker, required this.symbol});

  final BrokerApp broker;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Grabber(),
          Row(
            children: [
              const Icon(Icons.open_in_new, color: TWColors.accent, size: 20),
              const SizedBox(width: TWSpace.sm),
              Expanded(child: Text('Open Broker', style: TWType.title3)),
            ],
          ),
          const SizedBox(height: TWSpace.lg),
          _kv(context, 'Symbol', symbol.toUpperCase()),
          const SizedBox(height: TWSpace.sm),
          _brokerRowKv(context),
          const SizedBox(height: TWSpace.lg),
          Container(
            padding: const EdgeInsets.all(TWSpace.md),
            decoration: BoxDecoration(
              color: TWColors.surfaceCard,
              borderRadius: BorderRadius.circular(TWRadius.card),
              border: Border.all(color: TWColors.hairline),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline,
                    size: 16, color: TWColors.textTertiary),
                const SizedBox(width: TWSpace.sm),
                Expanded(
                  child: Text(
                    'TradeWizz does not execute trades.\n'
                    'You will be redirected to your broker app.',
                    style: TWType.caption,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: TWSpace.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('confirm_open_broker'),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open Broker'),
              style: FilledButton.styleFrom(
                backgroundColor: TWColors.accent,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(TWRadius.button),
                ),
              ),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ),
          const SizedBox(height: TWSpace.sm),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel',
                  style: TWType.label.copyWith(color: TWColors.textTertiary)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Row(
      children: [
        SizedBox(
            width: 80,
            child: Text(k,
                style: TWType.caption
                    .copyWith(color: TWColors.textTertiary))),
        Expanded(child: Text(v, style: TWType.label)),
      ],
    );
  }

  Widget _brokerRowKv(BuildContext context) {
    return Row(
      children: [
        SizedBox(
            width: 80,
            child: Text('Broker',
                style: TWType.caption
                    .copyWith(color: TWColors.textTertiary))),
        BrokerLogo(broker: broker, size: 22),
        const SizedBox(width: TWSpace.sm),
        Expanded(child: Text(broker.label, style: TWType.label)),
      ],
    );
  }
}

// ===========================================================================
// Preferred broker sheet (also reused by the long-press menu)
// ===========================================================================

/// Show a sheet to choose/change the preferred broker; persists the selection.
Future<void> showPreferredBrokerSheet(BuildContext context) async {
  final store = UserPrefsScope.maybeOf(context);
  if (store == null) return;
  final current = store.prefs.preferredBrokerId;
  final picked = await showModalBottomSheet<_PrefResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: TWColors.sheetScrim,
    builder: (ctx) => _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Grabber(),
          Text('Preferred broker', style: TWType.title3),
          const SizedBox(height: TWSpace.xs),
          Text('Used by the quick Open Broker action.', style: TWType.caption),
          const SizedBox(height: TWSpace.md),
          _PrefTile(
            label: 'No default',
            selected: current == null,
            onTap: () => Navigator.of(ctx).pop(const _PrefResult(null)),
          ),
          const SizedBox(height: TWSpace.sm),
          for (final b in BrokerApp.values) ...[
            _PrefTile(
              broker: b,
              label: b.label,
              selected: current == b.id,
              onTap: () => Navigator.of(ctx).pop(_PrefResult(b.id)),
            ),
            const SizedBox(height: TWSpace.sm),
          ],
        ],
      ),
    ),
  );
  if (picked != null) {
    await store.setPreferredBroker(picked.id);
  }
}

class _PrefResult {
  const _PrefResult(this.id);
  final String? id;
}

class _PrefTile extends StatelessWidget {
  const _PrefTile({
    this.broker,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final BrokerApp? broker;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? TWColors.accent.withValues(alpha: 0.12)
          : TWColors.surfaceCard,
      borderRadius: BorderRadius.circular(TWRadius.card),
      child: InkWell(
        key: Key('preferred_pick_${broker?.id ?? 'none'}'),
        borderRadius: BorderRadius.circular(TWRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: TWSpace.lg, vertical: TWSpace.md),
          child: Row(
            children: [
              if (broker != null) ...[
                BrokerLogo(broker: broker!, size: 30),
                const SizedBox(width: TWSpace.md),
              ] else ...[
                const SizedBox(
                    width: 30,
                    height: 30,
                    child: Icon(Icons.block, color: TWColors.textTertiary)),
                const SizedBox(width: TWSpace.md),
              ],
              Expanded(child: Text(label, style: TWType.label)),
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: selected ? TWColors.accent : TWColors.textTertiary,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Shared sheet building blocks
// ===========================================================================

class _SheetShell extends StatelessWidget {
  const _SheetShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: TWColors.bgRaised,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(TWRadius.cardLg)),
          border: Border(top: BorderSide(color: TWColors.hairlineTop)),
        ),
        padding: const EdgeInsets.fromLTRB(
            TWSpace.lg, TWSpace.md, TWSpace.lg, TWSpace.xl),
        child: child,
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: TWSpace.lg),
        decoration: BoxDecoration(
          color: TWColors.hairlineTop,
          borderRadius: BorderRadius.circular(TWRadius.chip),
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TWColors.surfaceCard,
      borderRadius: BorderRadius.circular(TWRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(TWRadius.card),
        onTap: onTap,
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
                child: Icon(icon, color: TWColors.accent, size: 18),
              ),
              const SizedBox(width: TWSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TWType.label),
                    Text(subtitle, style: TWType.caption),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: TWColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrokerRow extends StatelessWidget {
  const _BrokerRow({
    required this.broker,
    required this.preferred,
    required this.onTap,
  });

  final BrokerApp broker;
  final bool preferred;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TWColors.surfaceCard,
      borderRadius: BorderRadius.circular(TWRadius.card),
      child: InkWell(
        key: Key('broker_pick_${broker.id}'),
        borderRadius: BorderRadius.circular(TWRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: TWSpace.lg, vertical: TWSpace.md),
          child: Row(
            children: [
              BrokerLogo(broker: broker, size: 36),
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
              const Icon(Icons.chevron_right, color: TWColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
