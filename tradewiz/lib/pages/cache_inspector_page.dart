import 'package:flutter/material.dart';

import '../cache/cache_service.dart';
import '../theme.dart';

/// Developer-only Cache Inspector (Phase L).
///
/// Lists every cache entry with its age, TTL and stale flag, and lets you clear
/// all or individual entries. Reached from Account → Cache Inspector (only
/// shown in debug builds).
class CacheInspectorPage extends StatefulWidget {
  const CacheInspectorPage({super.key, this.service});

  final CacheService? service;

  @override
  State<CacheInspectorPage> createState() => _CacheInspectorPageState();
}

class _CacheInspectorPageState extends State<CacheInspectorPage> {
  CacheService get _cache => widget.service ?? CacheService.instance;

  List<CacheStat> _stats = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() => _stats = _cache.stats());

  Future<void> _clearAll() async {
    await _cache.clearAll();
    _reload();
  }

  Future<void> _clearOne(String key) async {
    await _cache.remove(key);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cache Inspector',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            key: const Key('cache_inspector_refresh'),
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const Key('cache_inspector_clear_all'),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Clear all cache'),
                  onPressed: _stats.isEmpty ? null : _clearAll,
                ),
              ),
            ),
            Expanded(
              child: _stats.isEmpty
                  ? const Center(
                      key: Key('cache_inspector_empty'),
                      child: Text('No cached data yet.',
                          style: TextStyle(color: Colors.grey)),
                    )
                  : ListView.separated(
                      key: const Key('cache_inspector_list'),
                      itemCount: _stats.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final s = _stats[i];
                        return ListTile(
                          key: Key('cache_row_${s.key}'),
                          leading: Icon(
                            s.stale
                                ? Icons.history_toggle_off
                                : Icons.check_circle_outline,
                            color: s.stale ? Colors.orange : AppColors.up,
                          ),
                          title: Text(s.label,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            '${s.stale ? 'stale' : 'cached'} • age: '
                            '${s.ageLabel} • ttl: ${_fmtTtl(s.ttl)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: IconButton(
                            key: Key('cache_clear_${s.key}'),
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => _clearOne(s.key),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTtl(Duration d) {
    if (d.inMinutes >= 1) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }
}
