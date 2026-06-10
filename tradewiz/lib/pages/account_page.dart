import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../models/broker.dart';
import '../models/simulation.dart';
import '../models/subscription.dart';
import '../widgets/portfolio_manager.dart';
import 'journal_page.dart';
import 'portfolio_page.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/entitlements_scope.dart';
import '../services/repository_scope.dart';
import '../services/social_sign_in.dart';
import '../theme_tradewizz.dart';
import '../widgets/ds/ds.dart';
import '../widgets/rebalance.dart';
import 'advanced_page.dart';
import '../widgets/premium.dart';
import 'ai_analysis_page.dart';
import 'auth_pages.dart';
import 'order_ticket_page.dart';
import 'upgrade_page.dart';

/// Account tab. Logged out -> Login / Register. Logged in -> profile + a
/// SIMULATED paper-trading portfolio (cash, equity, buying power, P/L,
/// holdings, trade history, reset). No broker connection is required or shown.
class AccountPage extends StatefulWidget {
  const AccountPage({super.key, this.repository, this.socialSignIn});

  final StockRepository? repository;

  /// Injectable social sign-in (Google/Apple). Defaults to the plugin-backed
  /// implementation; tests pass a fake.
  final SocialSignIn? socialSignIn;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  bool _loading = false;
  bool _failed = false;
  SimPortfolio? _portfolio;
  List<SimTrade> _trades = const [];
  String? _loadedForToken;
  bool _joiningWaitlist = false;
  // Portfolio Health (best-effort; never blocks the page).
  PortfolioHealth? _health;
  bool _healthLoading = false;

  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);
  String? get _token => AuthScope.of(context).token;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final token = _token;
    if (token != null && token != _loadedForToken && !_loading) {
      _load();
    } else if (token == null) {
      _portfolio = null;
      _trades = const [];
      _failed = false;
      _loadedForToken = null;
    }
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) return;
    setState(() {
      _loading = true;
      _failed = false;
      _loadedForToken = token;
    });
    try {
      final p = await _repo.simPortfolio(token);
      final t = await _repo.simTrades(token);
      if (!mounted) return;
      setState(() {
        _portfolio = p;
        _trades = t;
      });
    } on ApiException {
      if (mounted) setState(() => _failed = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    // Portfolio Health is best-effort and independent: a failure here must
    // never break the portfolio hub.
    unawaited(_loadHealth(token));
  }

  Future<void> _loadHealth(String token) async {
    if (!mounted) return;
    setState(() => _healthLoading = true);
    try {
      final h = await _repo.portfolioHealth(token);
      if (mounted) setState(() => _health = h);
    } catch (_) {
      // Swallowed: the card renders an unavailable state.
    } finally {
      if (mounted) setState(() => _healthLoading = false);
    }
  }

  /// Open the shared analysis/detail page for a held symbol. Buy/Sell from
  /// there are simulated (the same OrderTicketPage used everywhere).
  Future<void> _openDetail(SimPosition p) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AnalysisDetailPage(
        symbol: p.symbol,
        market: p.market,
        repository: widget.repository,
      ),
    ));
    if (mounted) await _load();
  }

  /// Open the simulated order ticket prefilled for this holding. SELL prefills
  /// and caps the quantity at the currently-held amount.
  Future<void> _openTicket(SimPosition p, OrderSide side) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrderTicketPage(
        symbol: p.symbol,
        market: p.market,
        side: side,
        repository: _repo,
        initialQuantity: side == OrderSide.sell ? p.quantity : null,
        maxQuantity: side == OrderSide.sell ? p.quantity : null,
      ),
    ));
    if (mounted) await _load();
  }

  Future<void> _reset() async {
    final token = _token;
    if (token == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset simulation portfolio?'),
        content: const Text(
          'This restores your simulated cash and clears all simulated '
          'positions and trade history. No real broker order is affected.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _loading = true);
    try {
      await _repo.simReset(token);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Join the early-access waiting list for [tier]. No payment is taken; we
  /// only record the intent (demand analytics) and confirm to the user.
  Future<void> _joinWaitlist(Tier tier) async {
    final token = _token;
    if (token == null) return;
    setState(() => _joiningWaitlist = true);
    try {
      await _repo.joinWaitlist(token, tier);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('waitlist_dialog'),
          title: Text('TradeWizz ${tier.label} is in preview'),
          content: Text(
            'TradeWizz ${tier.label} is currently in preview.\n\n'
            'You have been added to the early-access waiting list.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Got it'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not join the waiting list. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _joiningWaitlist = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final repo = _repo;

    if (!auth.isLoggedIn) {
      return _LoggedOutView(
        repository: repo,
        socialSignIn: widget.socialSignIn ?? PluginSocialSignIn(),
      );
    }
    final user = auth.user!;
    final port = _portfolio;
    final acct = port?.account;

    return TWScaffoldBackground(
      child: RefreshIndicator(
      onRefresh: _load,
      color: TWColors.accentBright,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          // --- Profile ---------------------------------------------------
          TWFloatingCard(
            padding: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: TWColors.accent.withValues(alpha: 0.12),
                  child: const Icon(Icons.person, color: TWColors.accent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Signed in as',
                          style:
                              TextStyle(color: TWColors.textTertiary, fontSize: 12)),
                      const SizedBox(height: 2),
                      Text(
                        user.email,
                        key: const Key('account_email'),
                        // Phase 10C: never wrap the email to a second line.
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                    ],
                  ),
                ),
                const TierChip(),
              ]),
            ),
          ),
          const SizedBox(height: 16),

          // --- Early Access Program -------------------------------------
          _EarlyAccessCard(
            busy: _joiningWaitlist,
            onJoinPro: () => _joinWaitlist(Tier.pro),
            onJoinElite: () => _joinWaitlist(Tier.elite),
            onOpenPlans: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => UpgradePage(repository: widget.repository),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // --- Simulation disclaimer ------------------------------------
          _disclaimerBanner(port?.disclaimer),
          const SizedBox(height: 16),

          // ============================================================
          // SECTION: Portfolio (value, holdings, trade history)
          // ============================================================
          const _SectionHeader('Portfolio',
              key: Key('account_section_portfolio')),

          // --- Simulated portfolio summary ------------------------------
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('Simulation Portfolio',
                key: Key('account_portfolio_section'),
                style:
                    TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          _SummaryCard(
            loading: _loading,
            failed: _failed,
            account: acct,
            onRetry: _load,
          ),
          const SizedBox(height: 16),

          // --- Holdings --------------------------------------------------
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('Holdings',
                style:
                    TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
          _HoldingsCard(
            positions: port?.positions ?? const [],
            onOpen: _openDetail,
            onBuy: (p) => _openTicket(p, OrderSide.buy),
            onSell: (p) => _openTicket(p, OrderSide.sell),
          ),
          const SizedBox(height: 16),

          // --- Trade history ---------------------------------------------
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('Trade History',
                style:
                    TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
          _TradesCard(trades: _trades),
          const SizedBox(height: 24),

          // ============================================================
          // SECTION: Insights (journal, health, AI manager)
          // ============================================================
          const _SectionHeader('Insights',
              key: Key('account_section_insights')),

          // --- Trade Journal (user-facing investing feature) ------------
          _LinkCard(
            cardKey: const Key('account_journal_link'),
            icon: Icons.menu_book_outlined,
            title: 'Trade Journal',
            subtitle: 'Review your simulated trades and win rate.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => JournalPage(repository: widget.repository),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // --- Portfolio Health -----------------------------------------
          // Header + card grouped into one list item so the lazy ListView
          // builds them together (keeps presence assertions stable).
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 8),
                child: Text('Portfolio Health',
                    key: Key('account_health_section'),
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ),
              _PortfolioHealthCard(
                health: _health,
                loading: _healthLoading,
              ),
            ],
          ),
          const SizedBox(height: 24),

          // --- Portfolio Manager (AI) -----------------------------------
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('Portfolio Manager',
                key: Key('account_manager_section'),
                style:
                    TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
          PortfolioManagerCard(repository: widget.repository),
          const SizedBox(height: 24),

          // --- Portfolio Rebalancing AI ---------------------------------
          RebalanceCard(repository: widget.repository),
          const SizedBox(height: 24),

          // ============================================================
          // SECTION: Connections (external broker portfolio)
          // ============================================================
          const _SectionHeader('Connections',
              key: Key('account_section_connections')),

          // --- Connected Brokers Portfolio (single source of truth) -----
          _LinkCard(
            cardKey: const Key('account_brokers_portfolio_link'),
            icon: Icons.account_balance_outlined,
            title: 'Connected Brokers',
            subtitle: 'Connect or review an external broker portfolio.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PortfolioPage(repository: widget.repository),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ============================================================
          // SECTION: Account (subscription, advanced tools, reset/logout)
          // ============================================================
          const _SectionHeader('Account',
              key: Key('account_section_account')),

          // --- Advanced Tools: low-frequency / developer features -------
          _LinkCard(
            cardKey: const Key('account_advanced_link'),
            icon: Icons.tune,
            title: 'Advanced Tools',
            subtitle: 'Developer tools, cache, snapshot & analytics.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdvancedPage()),
            ),
          ),
          const SizedBox(height: 16),

          // --- Reset -----------------------------------------------------
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('reset_simulation_button'),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset Simulation Portfolio'),
              style: OutlinedButton.styleFrom(
                foregroundColor: TWColors.accent,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _loading ? null : _reset,
            ),
          ),
          const SizedBox(height: 12),

          // --- Logout ----------------------------------------------------
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('logout_button'),
              icon: const Icon(Icons.logout),
              label: const Text('Log out'),
              style: OutlinedButton.styleFrom(
                foregroundColor: TWColors.down,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: () async {
                final token = auth.token;
                if (token != null) {
                  try {
                    await repo.logout(token);
                  } catch (_) {}
                }
                await auth.clear();
              },
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _disclaimerBanner(String? text) => Container(
        key: const Key('account_sim_disclaimer'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          const Icon(Icons.science_outlined, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text ??
                  'This is a simulated portfolio. No real broker order is sent.',
              style: const TextStyle(
                  color: Colors.orange,
                  fontWeight: FontWeight.w700,
                  fontSize: 13),
            ),
          ),
        ]),
      );
}

/// Phase 10C — a prominent "Portfolio Value" header rendered at the top of the
/// existing summary card, so the total value + return are the first thing the
/// user reads. Uses the existing [SimAccount]; no new data source.
class _PortfolioValueHeader extends StatelessWidget {
  const _PortfolioValueHeader({required this.account});
  final SimAccount account;

  String _money(double v, String currency) {
    final neg = v < 0;
    final a = v.abs();
    final s = a >= 1000 ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
    final parts = s.split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    final grouped = parts.length > 1 ? '$buf.${parts[1]}' : buf.toString();
    return '${neg ? '-' : ''}$currency $grouped';
  }

  @override
  Widget build(BuildContext context) {
    final a = account;
    final totalPnl = a.realizedPnl + a.unrealizedPnl;
    final basis = a.equity - totalPnl;
    final pct = basis.abs() < 0.0001 ? 0.0 : (totalPnl / basis) * 100;
    final up = totalPnl >= 0;
    final color = up ? TWColors.up : TWColors.down;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Portfolio Value',
                  style: TextStyle(color: TWColors.textTertiary, fontSize: 11)),
              Text(_money(a.equity, a.currency),
                  key: const Key('account_hero_value'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w900)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(up ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14, color: color),
            Text('${up ? '+' : ''}${pct.toStringAsFixed(1)}%',
                key: const Key('account_hero_return'),
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w800, fontSize: 13)),
          ],
        ),
      ],
    );
  }
}

/// A bold section header used to group Account into Portfolio / Insights /
/// Connections / Account. Keeps the page scannable instead of a long list.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 12,
          letterSpacing: 1.1,
          color: TWColors.accent.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// A consistent navigation card: icon, title, one-line explanation and a clear
/// chevron CTA. Used for Journal / Connected Brokers / Advanced entries.
class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final Key cardKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TWFloatingCard(
      key: cardKey,
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          leading: Icon(icon, color: TWColors.accent),
          title: Text(title, style: TWType.label),
          subtitle: Text(subtitle, style: TWType.caption),
          trailing: const Icon(Icons.chevron_right,
              color: TWColors.textTertiary),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.loading,
    required this.failed,
    required this.account,
    required this.onRetry,
  });

  final bool loading;
  final bool failed;
  final SimAccount? account;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final a = account;
    Widget stat(String label, String value, {Color? color, Key? key}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(color: TWColors.textTertiary, fontSize: 11)),
            const SizedBox(height: 2),
            Text(value,
                key: key,
                style: TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 16, color: color)),
          ],
        );

    return TWFloatingCard(
      key: const Key('account_portfolio_card'),
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (loading && a == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else if (a == null && failed)
              Row(children: [
                const Icon(Icons.info_outline, size: 18, color: TWColors.textTertiary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    "Couldn't load your simulation portfolio right now.",
                    key: Key('account_portfolio_error'),
                    style: TextStyle(color: TWColors.textTertiary, fontSize: 13),
                  ),
                ),
                TextButton(onPressed: onRetry, child: const Text('Retry')),
              ])
            else if (a != null) ...[
              // Phase 10C: lead with the total Portfolio Value + return so the
              // hub reads as an investor home, not a settings page.
              _PortfolioValueHeader(account: a),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  stat('Simulated Cash', a.cash.toStringAsFixed(2),
                      key: const Key('account_cash')),
                  stat('Equity', a.equity.toStringAsFixed(2),
                      key: const Key('account_total_equity')),
                  stat('Buying Power', a.buyingPower.toStringAsFixed(2),
                      key: const Key('account_buying_power')),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  stat(
                    'Unrealized P/L',
                    '${a.unrealizedPnl >= 0 ? '+' : ''}'
                        '${a.unrealizedPnl.toStringAsFixed(2)}',
                    color: a.unrealizedPnl >= 0 ? TWColors.up : TWColors.down,
                    key: const Key('account_unrealized_pnl'),
                  ),
                  stat(
                    'Realized P/L',
                    '${a.realizedPnl >= 0 ? '+' : ''}'
                        '${a.realizedPnl.toStringAsFixed(2)}',
                    color: a.realizedPnl >= 0 ? TWColors.up : TWColors.down,
                    key: const Key('account_realized_pnl'),
                  ),
                  stat('Currency', a.currency),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HoldingsCard extends StatelessWidget {
  const _HoldingsCard({
    required this.positions,
    required this.onOpen,
    required this.onBuy,
    required this.onSell,
  });
  final List<SimPosition> positions;
  final ValueChanged<SimPosition> onOpen;
  final ValueChanged<SimPosition> onBuy;
  final ValueChanged<SimPosition> onSell;

  @override
  Widget build(BuildContext context) {
    if (positions.isEmpty) {
      return const TWFloatingCard(
        key: Key('account_holdings_empty'),
        padding: EdgeInsets.all(16),
        child: Padding(
          padding: EdgeInsets.zero,
          child: Text('No simulated holdings yet. Buy a stock to get started.',
              style: TextStyle(color: TWColors.textTertiary, fontSize: 13)),
        ),
      );
    }
    return TWFloatingCard(
      key: const Key('account_holdings_card'),
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (var i = 0; i < positions.length; i++) ...[
              if (i > 0)
                const Divider(height: 1, color: TWColors.hairline),
              _holdingTile(positions[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _holdingTile(SimPosition p) {
    final pnlColor = p.unrealizedPnl >= 0 ? TWColors.up : TWColors.down;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: Key('holding_tile_${p.symbol}_${p.market.code}'),
          onTap: () => onOpen(p),
          title: Text('${p.symbol} · ${p.market.code}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(
              '${p.quantity.toStringAsFixed(0)} @ '
              '${p.averageCost.toStringAsFixed(2)} '
              '· last ${p.lastPrice.toStringAsFixed(2)}'),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(p.marketValue.toStringAsFixed(2),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(
                '${p.unrealizedPnl >= 0 ? '+' : ''}'
                '${p.unrealizedPnl.toStringAsFixed(2)}',
                style: TextStyle(color: pnlColor, fontSize: 12),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Row(children: [
            Expanded(
              child: OutlinedButton(
                key: Key('holding_buy_${p.symbol}_${p.market.code}'),
                onPressed: () => onBuy(p),
                child: const Text('Buy'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                key: Key('holding_sell_${p.symbol}_${p.market.code}'),
                onPressed: () => onSell(p),
                style: OutlinedButton.styleFrom(
                    foregroundColor: TWColors.down),
                child: const Text('Sell'),
              ),
            ),
          ]),
        ),
      ],
    );
  }
}

class _TradesCard extends StatelessWidget {
  const _TradesCard({required this.trades});
  final List<SimTrade> trades;

  @override
  Widget build(BuildContext context) {
    if (trades.isEmpty) {
      return const TWFloatingCard(
        key: Key('account_trades_empty'),
        padding: EdgeInsets.all(16),
        child: Padding(
          padding: EdgeInsets.zero,
          child: Text('No simulated trades yet.',
              style: TextStyle(color: TWColors.textTertiary, fontSize: 13)),
        ),
      );
    }
    final shown = trades.take(20).toList();
    return TWFloatingCard(
      key: const Key('account_trades_card'),
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0)
                const Divider(height: 1, color: TWColors.hairline),
              _tradeTile(shown[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tradeTile(SimTrade t) {
    final isBuy = t.side == 'BUY';
    final color = isBuy ? TWColors.up : TWColors.down;
    return ListTile(
      dense: true,
      leading: Icon(isBuy ? Icons.arrow_downward : Icons.arrow_upward,
          color: color, size: 18),
      title: Text('${t.side} ${t.quantity.toStringAsFixed(0)} ${t.symbol}',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text('${t.market.code} @ ${t.price.toStringAsFixed(2)}'),
      trailing: Text(t.value.toStringAsFixed(2),
          style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

class _PortfolioHealthCard extends StatelessWidget {
  const _PortfolioHealthCard({required this.health, required this.loading});
  final PortfolioHealth? health;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final h = health;
    if (h == null) {
      return TWFloatingCard(
        key: const Key('account_health_card'),
        padding: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: loading
              ? const Center(
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : const Text(
                  'No portfolio health yet. Buy a stock to see your '
                  'health score, strengths and warnings.',
                  style: TextStyle(color: TWColors.textTertiary, fontSize: 13)),
        ),
      );
    }
    final score = h.healthScore;
    final color = score >= 70
        ? TWColors.up
        : score >= 40
            ? Colors.orange
            : TWColors.down;
    return TWFloatingCard(
      key: const Key('account_health_card'),
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(score.toStringAsFixed(0),
                  key: const Key('account_health_score'),
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 28,
                      color: color)),
              const SizedBox(width: 8),
              Text('/ 100  ${h.rating}',
                  style: const TextStyle(
                      color: TWColors.textTertiary, fontWeight: FontWeight.w600)),
            ]),
            if (h.strengths.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final s in h.strengths.take(2))
                Row(children: [
                  const Icon(Icons.check_circle_outline,
                      size: 16, color: TWColors.up),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(s,
                          style: const TextStyle(fontSize: 12))),
                ]),
            ],
            if (h.warnings.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final w in h.warnings.take(2))
                Row(children: [
                  const Icon(Icons.warning_amber_outlined,
                      size: 16, color: Colors.orange),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(w,
                          style: const TextStyle(fontSize: 12))),
                ]),
            ],
          ],
        ),
      ),
    );
  }
}

class _LoggedOutView extends StatefulWidget {
  const _LoggedOutView({required this.repository, required this.socialSignIn});
  final StockRepository repository;
  final SocialSignIn socialSignIn;

  @override
  State<_LoggedOutView> createState() => _LoggedOutViewState();
}

class _LoggedOutViewState extends State<_LoggedOutView> {
  bool _busy = false;
  String? _error;

  Future<void> _social(
    String provider,
    Future<String?> Function() getIdToken,
    Future<dynamic> Function(String idToken) exchange,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = AuthScope.of(context);
    try {
      final idToken = await getIdToken();
      if (idToken == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final res = await exchange(idToken);
      await auth.setSession(res.accessToken, res.user);
    } catch (e) {
      if (mounted) {
        setState(() => _error = _humanError(provider, e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanError(String provider, Object e) {
    final msg = e.toString();
    if (msg.contains('not configured')) return msg.replaceAll('Exception: ', '');
    if (msg.contains('already exists')) {
      return msg.replaceAll('Exception: ', '');
    }
    return '$provider sign-in failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final social = widget.socialSignIn;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.account_circle_outlined, size: 64,
                color: TWColors.textTertiary),
            const SizedBox(height: 12),
            const Text(
              'Sign in to TradeWiz',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            const SizedBox(height: 4),
            const Text(
              'Track your simulated portfolio across all markets.',
              style: TextStyle(color: TWColors.textTertiary),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('go_login_button'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                LoginPage(repository: widget.repository),
                          ),
                        ),
                child: const Text('Login with Email'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                key: const Key('go_register_button'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                RegisterPage(repository: widget.repository),
                          ),
                        ),
                child: const Text('Register with Email'),
              ),
            ),
            if (social.googleAvailable || social.appleAvailable) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      'or continue with',
                      style: const TextStyle(
                        color: TWColors.textTertiary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 16),
            ],
            if (social.googleAvailable)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const Key('continue_google_button'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _busy
                      ? null
                      : () => _social(
                            'Google',
                            social.googleIdToken,
                            widget.repository.googleLogin,
                          ),
                  icon: const Icon(Icons.g_mobiledata, size: 28),
                  label: const Text('Continue with Google'),
                ),
              ),
            if (social.appleAvailable) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const Key('continue_apple_button'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _busy
                      ? null
                      : () => _social(
                            'Apple',
                            social.appleIdToken,
                            widget.repository.appleLogin,
                          ),
                  icon: const Icon(Icons.apple, size: 22),
                  label: const Text('Continue with Apple'),
                ),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                key: const Key('social_error'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Early Access Program card (PRO/ELITE Preview pivot).
///
/// Shows the user's current status ("Preview User") and lets them join the
/// PRO / ELITE early-access waiting list. No prices, no payment — joining only
/// records demand. A link to the full Plans page is also offered.
class _EarlyAccessCard extends StatelessWidget {
  const _EarlyAccessCard({
    required this.busy,
    required this.onJoinPro,
    required this.onJoinElite,
    required this.onOpenPlans,
  });

  final bool busy;
  final VoidCallback onJoinPro;
  final VoidCallback onJoinElite;
  final VoidCallback onOpenPlans;

  @override
  Widget build(BuildContext context) {
    final ent = EntitlementsScope.entitlements(context);
    final status = ent.preview && ent.tier == Tier.free
        ? 'Preview User'
        : ent.tier.label;
    return Container(
      key: const Key('account_early_access_card'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2B1A4A), Color(0xFF4A2D8C)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.workspace_premium, color: Color(0xFFFFD54F)),
              const SizedBox(width: 8),
              const Text('Early Access Program',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD54F).withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(status,
                    key: const Key('early_access_status'),
                    style: const TextStyle(
                        color: Color(0xFFFFD54F),
                        fontWeight: FontWeight.w800,
                        fontSize: 11)),
              ),
            ]),
            const SizedBox(height: 8),
            const Text(
              'Unlock PRO & ELITE — Opportunity Radar, Multibagger Finder & '
              'Portfolio Health. Free during preview.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 42,
              child: FilledButton.icon(
                key: const Key('open_plans_link'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD54F),
                  foregroundColor: const Color(0xFF2B1A4A),
                ),
                onPressed: onOpenPlans,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('See all plans',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('join_pro_waitlist'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.4)),
                  ),
                  icon: const Icon(Icons.notifications_active_outlined,
                      size: 18),
                  onPressed: busy ? null : onJoinPro,
                  label: const Text('Join PRO'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('join_elite_waitlist'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.4)),
                  ),
                  icon: const Icon(Icons.workspace_premium, size: 18),
                  onPressed: busy ? null : onJoinElite,
                  label: const Text('Join ELITE'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
