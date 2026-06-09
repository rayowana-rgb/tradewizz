import 'package:flutter/material.dart';

import '../models/phase2.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';

/// Notification Center — lists in-app notifications (Elite opportunities,
/// multibagger candidates, portfolio-health warnings, new daily picks).
/// No push provider; in-app only.
class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key, this.repository});

  final StockRepository? repository;

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  bool _loading = true;
  bool _error = false;
  NotificationList _data = const NotificationList();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() {
        _loading = false;
        _error = false;
        _data = const NotificationList();
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final n = await _repo.notifications(token);
      if (!mounted) return;
      setState(() {
        _data = n;
        _loading = false;
        _error = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  Future<void> _markAllRead() async {
    final token = _token;
    if (token == null) return;
    try {
      await _repo.markNotificationsRead(token);
    } on ApiException {
      // best-effort
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (_data.unreadCount > 0)
            TextButton(
              key: const Key('notifications_mark_all_read'),
              onPressed: _markAllRead,
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('notifications_loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_token == null) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text('Sign in to see your notifications.',
                  style: TextStyle(color: Colors.grey)),
            ),
          ),
        ],
      );
    }
    if (_error) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text('Notifications unavailable.',
                  key: Key('notifications_error'),
                  style: TextStyle(color: AppColors.down)),
            ),
          ),
        ],
      );
    }
    if (_data.notifications.isEmpty) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text("You're all caught up.",
                  key: Key('notifications_empty'),
                  style: TextStyle(color: Colors.grey)),
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      key: const Key('notifications_list'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _data.notifications.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) =>
          _NotificationTile(notification: _data.notifications[i]),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification});
  final AppNotification notification;

  IconData get _icon {
    switch (notification.notificationType) {
      case 'new_elite_opportunity':
        return Icons.bolt;
      case 'new_multibagger_candidate':
        return Icons.rocket_launch_outlined;
      case 'portfolio_health_warning':
        return Icons.health_and_safety_outlined;
      case 'daily_pick_published':
        return Icons.today_outlined;
      default:
        return Icons.notifications_outlined;
    }
  }

  Color get _color {
    switch (notification.notificationType) {
      case 'portfolio_health_warning':
        return AppColors.down;
      case 'new_elite_opportunity':
        return AppColors.up;
      default:
        return AppColors.seed;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('notification_${notification.id}'),
      color: notification.read
          ? null
          : AppColors.seed.withValues(alpha: 0.05),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: _color.withValues(alpha: 0.12),
          child: Icon(_icon, color: _color, size: 20),
        ),
        title: Text(notification.title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        subtitle: Text(notification.body,
            style: const TextStyle(fontSize: 12)),
        trailing: notification.read
            ? null
            : Container(
                key: const Key('notification_unread_dot'),
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: AppColors.seed,
                  shape: BoxShape.circle,
                ),
              ),
      ),
    );
  }
}
