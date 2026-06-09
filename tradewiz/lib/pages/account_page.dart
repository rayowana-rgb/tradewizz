import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../models/broker.dart';
import '../models/simulation.dart';
import '../models/subscription.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/entitlements_scope.dart';
import '../services/repository_scope.dart';
import '../services/social_sign_in.dart';
import '../theme.dart';
import '../widgets/rebalance.dart';
import 'cache_inspector_page.dart';
import 'snapshot_inspector_page.dart';
import 'journal_page.dart';
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

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          // --- Profile ---------------------------------------------------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: AppColors.seed.withValues(alpha: 0.12),
                  child: const Icon(Icons.person, color: AppColors.seed),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Signed in as',
                          style:
                              TextStyle(color: Colors.grey, fontSize: 12)),
                      const SizedBox(height: 2),
                      Text(
                        user.email,
                        // ignore: prefer_const_constructors
                        key: const Key('account_email'),
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

          // --- Portfolio Rebalancing AI ---------------------------------
          RebalanceCard(repository: widget.repository),
          const SizedBox(height: 24),

          // --- Portfolio Journal & AI Manager ---------------------------
          Card(
            key: const Key('account_journal_link'),
            child: ListTile(
              leading: const Icon(Icons.smart_toy_outlined,
                  color: AppColors.seed),
              title: const Text('AI Portfolio Manager & Journal',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text(
                  'Rule-based guidance + your simulated trade diary.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(
                      title: const Text('Portfolio Insights',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    body: SafeArea(
                      child: JournalPage(repository: widget.repository),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // --- Cache Inspector (debug builds only, Phase L) -------------
          if (kDebugMode) ...[
            Card(
              key: const Key('account_cache_inspector_link'),
              child: ListTile(
                leading: const Icon(Icons.storage_outlined,
                    color: AppColors.seed),
                title: const Text('Cache Inspector',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text(
                    'Developer tool: inspect & clear the local cache.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const CacheInspectorPage(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              key: const Key('account_snapshot_inspector_link'),
              child: ListTile(
                leading: const Icon(Icons.dashboard_customize_outlined,
                    color: AppColors.seed),
                title: const Text('Snapshot Inspector',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text(
                    'Developer tool: snapshot age, TTL, size & refresh.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SnapshotInspectorPage(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // --- Reset -----------------------------------------------------
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('reset_simulation_button'),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset Simulation Portfolio'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.seed,
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
                foregroundColor: AppColors.down,
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
                style: const TextStyle(color: Colors.grey, fontSize: 11)),
            const SizedBox(height: 2),
            Text(value,
                key: key,
                style: TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 16, color: color)),
          ],
        );

    return Card(
      key: const Key('account_portfolio_card'),
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
                const Icon(Icons.info_outline, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    "Couldn't load your simulation portfolio right now.",
                    key: Key('account_portfolio_error'),
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
                TextButton(onPressed: onRetry, child: const Text('Retry')),
              ])
            else if (a != null) ...[
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
                    color: a.unrealizedPnl >= 0 ? AppColors.up : AppColors.down,
                    key: const Key('account_unrealized_pnl'),
                  ),
                  stat(
                    'Realized P/L',
                    '${a.realizedPnl >= 0 ? '+' : ''}'
                        '${a.realizedPnl.toStringAsFixed(2)}',
                    color: a.realizedPnl >= 0 ? AppColors.up : AppColors.down,
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
      return const Card(
        key: Key('account_holdings_empty'),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No simulated holdings yet. Buy a stock to get started.',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
        ),
      );
    }
    return Card(
      key: const Key('account_holdings_card'),
      child: Column(
        children: [
          for (var i = 0; i < positions.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _holdingTile(positions[i]),
          ],
        ],
      ),
    );
  }

  Widget _holdingTile(SimPosition p) {
    final pnlColor = p.unrealizedPnl >= 0 ? AppColors.up : AppColors.down;
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
                    foregroundColor: AppColors.down),
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
      return const Card(
        key: Key('account_trades_empty'),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No simulated trades yet.',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
        ),
      );
    }
    final shown = trades.take(20).toList();
    return Card(
      key: const Key('account_trades_card'),
      child: Column(
        children: [
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _tradeTile(shown[i]),
          ],
        ],
      ),
    );
  }

  Widget _tradeTile(SimTrade t) {
    final isBuy = t.side == 'BUY';
    final color = isBuy ? AppColors.up : AppColors.down;
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
                color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              'Sign in to TradeWiz',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            const SizedBox(height: 4),
            const Text(
              'Track your simulated portfolio across all markets.',
              style: TextStyle(color: Colors.grey),
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
                      style: TextStyle(
                        color: Colors.grey.shade600,
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
    return Card(
      key: const Key('account_early_access_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.science_outlined, color: AppColors.seed),
              const SizedBox(width: 8),
              const Text('Early Access Program',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const Spacer(),
              const TierChip(),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              const Text('Current Status:',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(width: 6),
              Text(status,
                  key: const Key('early_access_status'),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            const Text(
              'All PRO & ELITE features are open during preview. Join a '
              'waiting list to get early-access news. No payment is taken.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('join_pro_waitlist'),
                  icon: const Icon(Icons.notifications_active_outlined,
                      size: 18),
                  onPressed: busy ? null : onJoinPro,
                  label: const Text('Join PRO Waiting List'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('join_elite_waitlist'),
                  icon: const Icon(Icons.workspace_premium, size: 18),
                  onPressed: busy ? null : onJoinElite,
                  label: const Text('Join ELITE Waiting List'),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('open_plans_link'),
                onPressed: onOpenPlans,
                child: const Text('See all preview features'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
