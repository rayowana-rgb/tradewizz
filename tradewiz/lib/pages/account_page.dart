import 'package:flutter/material.dart';

import '../models/portfolio.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../services/social_sign_in.dart';
import '../theme.dart';
import 'auth_pages.dart';
import 'broker_connections_page.dart';
import 'portfolio_page.dart';

/// Account tab. Logged out -> Login / Register buttons. Logged in -> profile,
/// Broker Connections, a Portfolio section (summary + entry into the full
/// Portfolio page), and Logout.
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
  bool _loadingPortfolio = false;
  bool _portfolioFailed = false;
  UnifiedPortfolio? _portfolio;
  String? _loadedForToken;

  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);
  String? get _token => AuthScope.of(context).token;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final token = _token;
    // Load the portfolio summary once per signed-in session. Failure is
    // non-fatal: the Account page stays usable either way.
    if (token != null && token != _loadedForToken && !_loadingPortfolio) {
      _loadPortfolio();
    } else if (token == null) {
      _portfolio = null;
      _portfolioFailed = false;
      _loadedForToken = null;
    }
  }

  Future<void> _loadPortfolio() async {
    final token = _token;
    if (token == null) return;
    setState(() {
      _loadingPortfolio = true;
      _portfolioFailed = false;
      _loadedForToken = token;
    });
    try {
      final p = await _repo.portfolio(token);
      if (!mounted) return;
      setState(() => _portfolio = p);
    } on ApiException {
      if (mounted) setState(() => _portfolioFailed = true);
    } catch (_) {
      if (mounted) setState(() => _portfolioFailed = true);
    } finally {
      if (mounted) setState(() => _loadingPortfolio = false);
    }
  }

  void _openPortfolio() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Portfolio')),
          body: SafeArea(child: PortfolioPage(repository: widget.repository)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context); // rebuilds on login/logout
    final repo = _repo;

    if (!auth.isLoggedIn) {
      return _LoggedOutView(
        repository: repo,
        socialSignIn: widget.socialSignIn ?? PluginSocialSignIn(),
      );
    }
    final user = auth.user!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
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
                            style: TextStyle(color: Colors.grey, fontSize: 12)),
                        const SizedBox(height: 2),
                        Text(
                          user.email,
                          key: const Key('account_email'),
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                Row(children: [
                  const Icon(Icons.account_balance, size: 18,
                      color: AppColors.seed),
                  const SizedBox(width: 8),
                  Text(
                    'Connected brokers: ${user.connectedBrokers}',
                    key: const Key('connected_brokers'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            key: const Key('broker_connections_tile'),
            leading: const Icon(Icons.account_balance_wallet_outlined,
                color: AppColors.seed),
            title: const Text('Broker Connections'),
            subtitle: Text('${user.connectedBrokers} connected'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BrokerConnectionsPage(repository: repo),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // --- Portfolio section -------------------------------------------
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text('Portfolio',
              key: Key('account_portfolio_section'),
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ),
        _PortfolioCard(
          loading: _loadingPortfolio,
          failed: _portfolioFailed,
          portfolio: _portfolio,
          onOpen: _openPortfolio,
          onRetry: _loadPortfolio,
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            ListTile(
              key: const Key('portfolio_positions_tile'),
              leading: const Icon(Icons.list_alt_outlined,
                  color: AppColors.seed),
              title: const Text('Positions'),
              subtitle: const Text('Holdings across your brokers'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openPortfolio,
            ),
            const Divider(height: 1),
            ListTile(
              key: const Key('portfolio_performance_tile'),
              leading: const Icon(Icons.insights_outlined,
                  color: AppColors.seed),
              title: const Text('Performance Analytics'),
              subtitle: const Text('P/L, breakdowns and equity curve'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openPortfolio,
            ),
          ]),
        ),
        const SizedBox(height: 16),
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
                // Best-effort server notify; clear locally regardless.
                try {
                  await repo.logout(token);
                } catch (_) {}
              }
              await auth.clear();
            },
          ),
        ),
      ],
    );
  }
}

/// Portfolio summary card shown inside the Account page. Shows total equity,
/// cash and (when present) floating P/L, with an Open Portfolio button. If the
/// summary fails to load it degrades to a friendly message but always keeps the
/// Open Portfolio button available so the section stays usable.
class _PortfolioCard extends StatelessWidget {
  const _PortfolioCard({
    required this.loading,
    required this.failed,
    required this.portfolio,
    required this.onOpen,
    required this.onRetry,
  });

  final bool loading;
  final bool failed;
  final UnifiedPortfolio? portfolio;
  final VoidCallback onOpen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = portfolio?.summary;
    final hasData = s != null;
    final pnlColor =
        (s?.floatingPnl ?? 0) >= 0 ? AppColors.up : AppColors.down;

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
            Row(children: [
              const Icon(Icons.pie_chart_outline, color: AppColors.seed),
              const SizedBox(width: 10),
              const Text('Portfolio Summary',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              if (loading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ]),
            const SizedBox(height: 14),
            if (hasData) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  stat('Total Equity', s.totalEquity.toStringAsFixed(2),
                      key: const Key('account_total_equity')),
                  stat('Cash', s.cash.toStringAsFixed(2),
                      key: const Key('account_cash')),
                  stat(
                    'Floating P/L',
                    '${s.floatingPnl >= 0 ? '+' : ''}'
                        '${s.floatingPnl.toStringAsFixed(2)}',
                    color: pnlColor,
                    key: const Key('account_floating_pnl'),
                  ),
                ],
              ),
            ] else if (failed) ...[
              Row(children: [
                const Icon(Icons.info_outline,
                    size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    "Couldn't load your portfolio summary right now.",
                    key: Key('account_portfolio_error'),
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ]),
            ] else if (!loading) ...[
              const Text('Open your portfolio to see equity and positions.',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('open_portfolio_button'),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open Portfolio'),
                onPressed: onOpen,
              ),
            ),
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
        // User cancelled.
        if (mounted) setState(() => _busy = false);
        return;
      }
      final res = await exchange(idToken);
      // Persist ONLY the TradeWizz session, never the provider token.
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
    // Surface the backend's clear messages (already user-facing).
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
              'Manage your profile and brokers.',
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
