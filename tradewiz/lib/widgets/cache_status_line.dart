import 'package:flutter/material.dart';

import '../cache/cache_entry.dart';
import '../theme.dart';

/// Small "Updated 5 min ago" / "Cached • 5 min ago" line shown under cached
/// sections. When [offline] is set it reads "Offline • Cached 5 min ago".
class CacheStatusLine extends StatelessWidget {
  const CacheStatusLine({
    super.key,
    required this.lastUpdated,
    required this.isCached,
    this.offline = false,
  });

  final DateTime lastUpdated;
  final bool isCached;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final ago = humanAgo(DateTime.now().difference(lastUpdated));
    final String label;
    final IconData icon;
    final Color color;
    if (offline) {
      label = 'Offline • Cached $ago';
      icon = Icons.cloud_off_outlined;
      color = AppColors.down;
    } else if (isCached) {
      label = 'Cached • $ago';
      icon = Icons.history;
      color = Colors.grey;
    } else {
      label = 'Updated $ago';
      icon = Icons.check_circle_outline;
      color = AppColors.up;
    }
    return Row(
      key: const Key('cache_status_line'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: color),
        ),
      ],
    );
  }
}

/// A thin warning banner shown when the screen is rendering cached data because
/// the backend was unreachable (Phase J – Offline Mode).
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.lastUpdated});

  final DateTime lastUpdated;

  @override
  Widget build(BuildContext context) {
    final ago = humanAgo(DateTime.now().difference(lastUpdated));
    return Container(
      key: const Key('offline_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined,
              size: 18, color: Color(0xFF8A6D00)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Showing cached data\nLast updated $ago',
              style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF8A6D00),
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
