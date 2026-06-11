import 'package:flutter/material.dart';

import 'cache_inspector_page.dart';
import 'snapshot_inspector_page.dart';
import '../widgets/global_rotation.dart';

/// Advanced Tools — low-frequency power-user and developer diagnostics.
///
/// User-facing investing features (Trade Journal, Connected Brokers Portfolio)
/// live in the Account page, NOT here, so each appears in exactly one place.
/// This page is reached from Account → Advanced Tools and holds only:
/// Global Rotation, Cache Inspector, Snapshot Inspector, and Analytics.
class AdvancedPage extends StatelessWidget {
  const AdvancedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Advanced Tools',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('advanced_list'),
          padding: const EdgeInsets.all(16),
          children: const [
            Padding(
              padding: EdgeInsets.only(left: 2, bottom: 12),
              child: Text(
                'Low-frequency tools and diagnostics.',
                key: Key('advanced_description'),
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
            _Tile(
              icon: Icons.public,
              title: 'Global Rotation',
              subtitle: 'Compare market strength across countries.',
              page: _GlobalRotationPage(),
            ),
            _Tile(
              icon: Icons.storage_outlined,
              title: 'Cache Inspector',
              subtitle: 'Inspect local app cache.',
              developer: true,
              page: CacheInspectorPage(),
            ),
            _Tile(
              icon: Icons.dashboard_customize_outlined,
              title: 'Snapshot Inspector',
              subtitle: 'Inspect snapshot / CDN data.',
              developer: true,
              page: SnapshotInspectorPage(),
            ),
            _Tile(
              icon: Icons.insights_outlined,
              title: 'Analytics',
              subtitle: 'Feature usage and demand signals.',
              developer: true,
              page: SnapshotInspectorPage(),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlobalRotationPage extends StatelessWidget {
  const _GlobalRotationPage();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Global Rotation',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: const SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: GlobalRotationCard(),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.page,
    this.developer = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget page;

  /// Debug/developer-only tool — flagged with a small "Developer Tool" chip so
  /// it never looks like a consumer investing feature.
  final bool developer;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        key: Key('advanced_${title.replaceAll(' ', '_').toLowerCase()}'),
        leading: Icon(icon),
        title: Row(
          children: [
            Flexible(
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            if (developer) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('Developer Tool',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => page),
        ),
      ),
    );
  }
}
