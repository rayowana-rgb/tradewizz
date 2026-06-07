import 'package:flutter/material.dart';

import '../repositories/stock_repository.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';
import 'auth_pages.dart';

/// Account tab. Logged out -> Login / Register buttons. Logged in -> email,
/// connected brokers count, and Logout.
class AccountPage extends StatelessWidget {
  const AccountPage({super.key, this.repository});

  final StockRepository? repository;

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context); // rebuilds on login/logout
    final repo = repository ?? RepositoryScope.of(context);

    if (!auth.isLoggedIn) {
      return _LoggedOutView(repository: repo);
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

class _LoggedOutView extends StatelessWidget {
  const _LoggedOutView({required this.repository});
  final StockRepository repository;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
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
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LoginPage(repository: repository),
                  ),
                ),
                child: const Text('Log in'),
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
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RegisterPage(repository: repository),
                  ),
                ),
                child: const Text('Create account'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
