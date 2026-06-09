import 'package:flutter/material.dart';

import 'cache_inspector_page.dart';
import 'journal_page.dart';
import 'snapshot_inspector_page.dart';
import '../widgets/global_rotation.dart';

/// Phase F — Advanced section.
///
/// Power-user features that used to clutter the default dashboard are tucked
/// here so they are NOT shown by default but remain fully available:
/// Global Rotation, Portfolio Journal, Cache Inspector, Snapshot Inspector,
/// and Advanced Analytics. Reached from Account → Advanced.
class AdvancedPage extends StatelessWidget {
  const AdvancedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Advanced',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('advanced_list'),
          padding: const EdgeInsets.all(16),
          children: [
            const _Tile(
              icon: Icons.public,
              title: 'Global Rotation',
              subtitle: 'Rank markets by opportunity environment.',
              page: _GlobalRotationPage(),
            ),
            const _Tile(
              icon: Icons.menu_book_outlined,
              title: 'Portfolio Journal',
              subtitle: 'Your research log and trade outcomes.',
              page: JournalPage(),
            ),
            const _Tile(
              icon: Icons.insights_outlined,
              title: 'Advanced Analytics',
              subtitle: 'Snapshot freshness, sources, and metrics.',
              page: SnapshotInspectorPage(),
            ),
            const _Tile(
              icon: Icons.storage_outlined,
              title: 'Cache Inspector',
              subtitle: 'Local cache contents and freshness.',
              page: CacheInspectorPage(),
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
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        key: Key('advanced_${title.replaceAll(' ', '_').toLowerCase()}'),
        leading: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => page),
        ),
      ),
    );
  }
}
