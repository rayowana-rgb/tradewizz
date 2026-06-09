import 'package:flutter/material.dart';

import '../cache/cache_entry.dart';
import '../cache/cache_service.dart';
import '../cdn/cdn_repository.dart';
import '../models/market.dart';
import '../snapshot/snapshot_keys.dart';
import '../snapshot/snapshot_metrics.dart';
import '../snapshot/snapshot_repository.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';

/// Developer-only Snapshot Inspector (Phase L).
///
/// Account → Developer Tools → Snapshot Inspector. Shows dashboard / portfolio
/// / watchlist snapshot age, TTL, size and last refresh, plus the Phase M
/// metrics. Buttons force-refresh each snapshot or clear them all.
class SnapshotInspectorPage extends StatefulWidget {
  const SnapshotInspectorPage({
    super.key,
    this.service,
    this.repository,
    this.cdn,
    this.market = Market.us,
  });

  final CacheService? service;
  final SnapshotRepository? repository;
  final CdnRepository? cdn;
  final Market market;

  @override
  State<SnapshotInspectorPage> createState() => _SnapshotInspectorPageState();
}

class _SnapshotInspectorPageState extends State<SnapshotInspectorPage> {
  CacheService get _cache => widget.service ?? CacheService.instance;
  SnapshotRepository get _repo =>
      widget.repository ?? RepositoryScope.snapshotOf(context);
  CdnRepository get _cdn => widget.cdn ?? RepositoryScope.cdnOf(context);
  SnapshotSource _lastSource = SnapshotSource.hive;

  bool _busy = false;
  String? _message;

  String? get _token =>
      context.getInheritedWidgetOfExactType<AuthScope>()?.notifier?.token;

  List<_SnapRow> _rows() {
    final rows = <_SnapRow>[];
    for (final key in [
      SnapshotKeys.dashboard(widget.market),
      SnapshotKeys.portfolio,
      SnapshotKeys.watchlist(widget.market),
    ]) {
      final entry = _cache.readEntry(key);
      rows.add(_SnapRow(
        key: key,
        label: SnapshotKeys.label(key),
        entry: entry,
        sizeBytes: entry == null ? 0 : entry.toString().length,
      ));
    }
    return rows;
  }

  Future<void> _refresh(String which) async {
    final token = _token;
    if (token == null) {
      setState(() => _message = 'Sign in to refresh snapshots.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      switch (which) {
        case 'dashboard':
          await _repo.fetchDashboardSnapshot(token, widget.market,
              force: true);
          break;
        case 'portfolio':
          await _repo.fetchPortfolioSnapshot(token, force: true);
          break;
        case 'watchlist':
          await _repo.fetchWatchlistSnapshot(token, widget.market,
              force: true);
          break;
      }
      setState(() => _message = 'Refreshed $which.');
    } catch (_) {
      setState(() => _message = 'Refresh failed (kept previous snapshot).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAll() async {
    for (final key in [
      SnapshotKeys.dashboard(widget.market),
      SnapshotKeys.portfolio,
      SnapshotKeys.watchlist(widget.market),
    ]) {
      await _cache.remove(key);
    }
    setState(() => _message = 'Cleared all snapshots.');
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    final m = _repo.metrics;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Snapshot Inspector',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            key: const Key('snapshot_inspector_refresh'),
            tooltip: 'Reload view',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('snapshot_inspector_list'),
          padding: const EdgeInsets.all(12),
          children: [
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_message!,
                    key: const Key('snapshot_inspector_message'),
                    style: const TextStyle(color: Colors.blueGrey)),
              ),
            for (final r in rows) _snapshotTile(r),
            const SizedBox(height: 16),
            _cdnCard(),
            const SizedBox(height: 16),
            _metricsCard(m),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('snapshot_clear_all'),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear Snapshots'),
                onPressed: _busy ? null : _clearAll,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _snapshotTile(_SnapRow r) {
    final entry = r.entry;
    final hasData = entry != null;
    final ttl = _ttlFor(r.key);
    return Card(
      key: Key('snapshot_row_${r.key}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  !hasData
                      ? Icons.cloud_off
                      : entry.stale
                          ? Icons.history_toggle_off
                          : Icons.check_circle_outline,
                  color: !hasData
                      ? Colors.grey
                      : entry.stale
                          ? Colors.orange
                          : AppColors.up,
                ),
                const SizedBox(width: 8),
                Text(r.label,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              hasData
                  ? 'age: ${_humanAge(entry.age)} • ttl: ${_fmtTtl(ttl)} • '
                      'size: ${r.sizeBytes}B • '
                      'last refresh: ${entry.cachedAt.toIso8601String()}'
                  : 'no snapshot stored',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                key: Key('snapshot_refresh_${SnapshotKeys.label(r.key)
                    .toLowerCase()}'),
                onPressed: _busy ? null : () => _refresh(_which(r.key)),
                child: Text('Refresh ${SnapshotKeys.label(r.key)}'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Phase J: CDN status — source, manifest/snapshot version, last sync, size.
  Widget _cdnCard() {
    final dashKey = SnapshotKeys.dashboard(widget.market);
    final entry = _cache.readEntry(dashKey);
    final manifest = _cdn.localManifest;
    final lastSync = _cdn.lastCdnSync;
    final size = entry == null ? 0 : entry.toString().length;
    final snapshotVersion = manifest?.markets[widget.market.code] ??
        manifest?.hashes['markets/${widget.market.code}/dashboard.json'] ??
        '—';
    return Card(
      key: const Key('snapshot_cdn_card'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_outlined, color: AppColors.seed),
                const SizedBox(width: 8),
                const Text('Snapshot CDN',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Container(
                  key: const Key('snapshot_source_badge'),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.seed.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('Source: ${_lastSource.label}',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _kv('CDN enabled', _cdn.enabled ? 'yes' : 'no'),
            _kv('Manifest version', manifest?.version ?? '—'),
            _kv('Snapshot version',
                snapshotVersion.length > 12
                    ? '${snapshotVersion.substring(0, 12)}…'
                    : snapshotVersion),
            _kv('Last CDN sync',
                lastSync == null ? 'never' : lastSync.toIso8601String()),
            _kv('Download size', '${size}B'),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                key: const Key('snapshot_cdn_sync'),
                onPressed: _busy ? null : _syncCdn,
                child: const Text('Sync from CDN'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            Text('$k: ',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Expanded(
              child: Text(v,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );

  Future<void> _syncCdn() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final res = await _cdn.sync(widget.market);
      setState(() {
        _lastSource = res.source;
        _message = res.changed
            ? 'Downloaded ${res.bytes}B from CDN (v${res.manifestVersion}).'
            : 'CDN unchanged — using ${res.source.label}.';
      });
    } catch (_) {
      setState(() => _message = 'CDN sync failed (kept Hive snapshot).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _metricsCard(SnapshotMetrics metrics) {
    // Merge snapshot-repo metrics with the CDN repo metrics so the inspector
    // shows the full Phase I counter set.
    final map = <String, Object>{...metrics.toMap()};
    _cdn.metrics.toMap().forEach((k, v) {
      if (k.startsWith('cdn_') ||
          k == 'snapshot_update' ||
          k == 'snapshot_bytes' ||
          k == 'offline_snapshot_load') {
        map[k] = v;
      }
    });
    return Card(
      key: const Key('snapshot_metrics'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Performance metrics',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final e in map.entries)
              Text('${e.key}: ${e.value}',
                  style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  String _which(String key) {
    if (key.startsWith('dashboard')) return 'dashboard';
    if (key == SnapshotKeys.portfolio) return 'portfolio';
    return 'watchlist';
  }

  Duration _ttlFor(String key) {
    if (key.startsWith('dashboard')) return SnapshotKeys.dashboardTtl;
    if (key == SnapshotKeys.portfolio) return SnapshotKeys.portfolioTtl;
    return SnapshotKeys.watchlistTtl;
  }

  String _fmtTtl(Duration d) =>
      d.inMinutes >= 1 ? '${d.inMinutes}m' : '${d.inSeconds}s';

  String _humanAge(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    return '${d.inHours}h';
  }
}

class _SnapRow {
  _SnapRow({
    required this.key,
    required this.label,
    required this.entry,
    required this.sizeBytes,
  });
  final String key;
  final String label;
  final CacheEntry<dynamic>? entry;
  final int sizeBytes;
}
