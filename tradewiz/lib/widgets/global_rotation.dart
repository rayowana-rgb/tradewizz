import 'dart:async';

import 'package:flutter/material.dart';

import '../cache/cache_entry.dart';
import '../cache/cache_service.dart';
import '../cache/cached_repository.dart';
import '../models/phase3.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';
import 'cache_status_line.dart';

Color recColor(String rec) => {
      'OVERWEIGHT': AppColors.up,
      'UNDERWEIGHT': Colors.orange,
      'AVOID': AppColors.down,
    }[rec] ??
    Colors.blueGrey;

/// "Global Rotation" dashboard card — best market today + a compact rank table.
class GlobalRotationCard extends StatefulWidget {
  const GlobalRotationCard({super.key, this.repository});

  final StockRepository? repository;

  @override
  State<GlobalRotationCard> createState() => _GlobalRotationCardState();
}

class _GlobalRotationCardState extends State<GlobalRotationCard> {
  CachedRepository get _cached => widget.repository != null
      ? CachedRepository(widget.repository!, cache: CacheService.inMemory())
      : RepositoryScope.cachedOf(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  bool _loading = true;
  bool _error = false;
  GlobalRotation? _data;
  DateTime? _lastUpdated;
  bool _isCached = false;
  bool _offline = false;
  StreamSubscription<Cached<GlobalRotation>>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading && _data == null) _load();
  }

  Future<void> _load() async {
    final token = _token;
    _sub?.cancel();
    if (token == null) {
      setState(() {
        _loading = false;
        _data = null;
      });
      return;
    }
    setState(() => _loading = true);
    // SWR: cache renders instantly; refresh runs in the background. If the
    // backend is unavailable, the cached rotation stays on screen.
    _sub = _cached.globalRotationSwr(token).listen(
      (c) {
        if (!mounted) return;
        setState(() {
          _data = c.value;
          _isCached = c.isCached;
          _offline = c.offline;
          _lastUpdated = c.lastUpdated;
          _loading = false;
          _error = false;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          if (_data == null) _error = true;
        });
      },
    );
  }

  void _openDetail() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          GlobalRotationDetailPage(repository: widget.repository, data: _data),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('global_rotation_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.public, color: AppColors.seed, size: 20),
            const SizedBox(width: 8),
            const Text('Global Rotation',
                key: Key('global_rotation_title'),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const Spacer(),
            if (_data != null)
              TextButton(
                key: const Key('global_rotation_view_all'),
                onPressed: _openDetail,
                child: const Text('View all'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          key: const Key('global_rotation_card'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildBody(),
          ),
        ),
        if (_data != null && _lastUpdated != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: CacheStatusLine(
              lastUpdated: _lastUpdated!,
              isCached: _isCached,
              offline: _offline,
            ),
          ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading && _data == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            key: Key('global_rotation_loading'),
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (_token == null) {
      return const Text('Sign in to see the best market today.',
          style: TextStyle(color: Colors.grey));
    }
    if (_error || _data == null) {
      return const Text('Global Rotation unavailable.',
          key: Key('global_rotation_error'),
          style: TextStyle(color: AppColors.down));
    }
    final data = _data!;
    final top = data.markets.take(4).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Best Market Today',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 2),
        Text(data.bestMarket,
            key: const Key('global_rotation_best_market'),
            style:
                const TextStyle(fontWeight: FontWeight.w900, fontSize: 22)),
        if (data.rotationSummary.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(data.rotationSummary,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
        const Divider(height: 22),
        for (final m in top) _RotationRow(m: m),
      ],
    );
  }
}

class _RotationRow extends StatelessWidget {
  const _RotationRow({required this.m});
  final MarketRotation m;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('rotation_row_${m.market.code}'),
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text('#${m.rank}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: Colors.grey)),
          ),
          Text('${m.market.flag} ${m.market.code}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(m.rotationScore.toStringAsFixed(0),
              style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: recColor(m.recommendation).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(m.recommendation,
                style: TextStyle(
                    color: recColor(m.recommendation),
                    fontWeight: FontWeight.w800,
                    fontSize: 9)),
          ),
        ],
      ),
    );
  }
}

/// Detail page — all markets with rank, score, regime, strong/elite counts,
/// and recommendation.
class GlobalRotationDetailPage extends StatefulWidget {
  const GlobalRotationDetailPage({super.key, this.repository, this.data});

  final StockRepository? repository;
  final GlobalRotation? data;

  @override
  State<GlobalRotationDetailPage> createState() =>
      _GlobalRotationDetailPageState();
}

class _GlobalRotationDetailPageState extends State<GlobalRotationDetailPage> {
  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  GlobalRotation? _data;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _data = widget.data;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_data == null && !_loading) _load();
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) return;
    setState(() => _loading = true);
    try {
      final r = await _repo.globalRotation(token);
      if (!mounted) return;
      setState(() {
        _data = r;
        _loading = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Global Rotation Engine',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: data == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: const Key('rotation_detail_list'),
              padding: const EdgeInsets.all(16),
              children: [
                if (data.rotationSummary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(data.rotationSummary,
                        style: const TextStyle(
                            fontSize: 13, color: Colors.black54)),
                  ),
                for (final m in data.markets) _DetailCard(m: m),
              ],
            ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.m});
  final MarketRotation m;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: Key('rotation_detail_${m.market.code}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Text('#${m.rank}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Colors.grey)),
                ),
                Text('${m.market.flag} ${m.market.name}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: recColor(m.recommendation).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(m.recommendation,
                      style: TextStyle(
                          color: recColor(m.recommendation),
                          fontWeight: FontWeight.w800,
                          fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                _kv('Rotation', m.rotationScore.toStringAsFixed(0)),
                _kv('Regime', _regimeLabel(m.regime)),
                _kv('Strong', '${m.strongCount}'),
                _kv('Elite', '${m.eliteCount}'),
                _kv('Breadth', '${m.breadth.toStringAsFixed(0)}%'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _regimeLabel(String r) =>
      {'BULL': 'Bullish', 'BEAR': 'Bearish', 'NEUTRAL': 'Neutral'}[r] ?? r;

  Widget _kv(String k, String v) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$k: ',
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
          Text(v,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        ],
      );
}
