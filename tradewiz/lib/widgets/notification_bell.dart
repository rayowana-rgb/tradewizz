import 'dart:async';

import 'package:flutter/material.dart';

import '../cache/cache_entry.dart';
import '../cache/cache_keys.dart';
import '../cache/cache_service.dart';
import '../cache/cached_repository.dart';
import '../models/phase2.dart';
import '../pages/notifications_page.dart';
import '../repositories/stock_repository.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';

/// AppBar bell icon with an unread-count badge. Tapping opens the Notification
/// Center. Polls the unread count once on build (best-effort, in-app only).
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key, this.repository});

  final StockRepository? repository;

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  CachedRepository get _cached => widget.repository != null
      ? CachedRepository(widget.repository!, cache: CacheService.inMemory())
      : RepositoryScope.cachedOf(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  int _unread = 0;
  bool _loaded = false;
  StreamSubscription<Cached<NotificationList>>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      // Phase H: show the cached badge count instantly, then SWR-refresh.
      final cachedNow = _cached.peek<NotificationList>(
        CacheKeys.notifications,
        (raw) => NotificationList.fromJson(
            (raw as Map).cast<String, dynamic>()),
      );
      if (cachedNow != null) _unread = cachedNow.value.unreadCount;
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final token = _token;
    _sub?.cancel();
    if (token == null) {
      if (mounted) setState(() => _unread = 0);
      return;
    }
    _sub = _cached.notificationsSwr(token).listen(
      (c) {
        if (!mounted) return;
        setState(() => _unread = c.value.unreadCount);
      },
      onError: (Object _) {
        // best-effort; leave the prior (cached) count on screen.
      },
    );
  }

  Future<void> _open() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotificationCenterPage(repository: widget.repository),
      ),
    );
    // Refresh the badge after returning (the user may have read items).
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('notification_bell'),
      tooltip: 'Notifications',
      onPressed: _open,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.notifications_outlined),
          if (_unread > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                key: const Key('notification_unread_badge'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                constraints:
                    const BoxConstraints(minWidth: 16, minHeight: 16),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _unread > 99 ? '99+' : '$_unread',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
