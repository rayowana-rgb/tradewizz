import 'package:flutter/material.dart';

import '../services/data_source.dart';
import '../theme.dart';

/// Small pill showing where the current data came from (live / fallback /
/// offline / error). Renders nothing while [source] is null (e.g. loading).
class ConnectionPill extends StatelessWidget {
  const ConnectionPill({super.key, required this.source});

  final DataSource? source;

  @override
  Widget build(BuildContext context) {
    final s = source;
    if (s == null) return const SizedBox.shrink();

    final (color, icon) = switch (s) {
      DataSource.live => (AppColors.up, Icons.cloud_done_outlined),
      DataSource.fallback => (Colors.orange, Icons.cloud_off_outlined),
      DataSource.offline => (Colors.grey, Icons.wifi_off_outlined),
      DataSource.error => (AppColors.down, Icons.error_outline),
    };

    return Tooltip(
      message: s.description,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              s.label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-width banner variant for prominent placement (e.g. top of a page).
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.source});

  final DataSource? source;

  @override
  Widget build(BuildContext context) {
    final s = source;
    // Only show a banner when something is off; live data needs no banner.
    if (s == null || s == DataSource.live) return const SizedBox.shrink();

    final color = switch (s) {
      DataSource.fallback => Colors.orange,
      DataSource.offline => Colors.grey,
      DataSource.error => AppColors.down,
      DataSource.live => AppColors.up,
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.description,
              style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
