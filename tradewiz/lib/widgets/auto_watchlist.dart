import 'package:flutter/material.dart';

import '../models/phase3.dart';
import '../models/watchlist_item.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../services/watchlist_scope.dart';
import '../theme.dart';

/// "Auto Watchlist AI" dashboard card — shows how many picks are suggested
/// today, with Apply All and Review Suggestions. Applying adds names to the
/// (client-side) watchlist + records server-side source metadata.
class AutoWatchlistCard extends StatefulWidget {
  const AutoWatchlistCard({super.key, this.repository});

  final StockRepository? repository;

  @override
  State<AutoWatchlistCard> createState() => _AutoWatchlistCardState();
}

class _AutoWatchlistCardState extends State<AutoWatchlistCard> {
  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  bool _loading = true;
  bool _busy = false;
  bool _error = false;
  AutoWatchlistSuggestions? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading && _data == null) _load();
  }

  List<String> _existingKeys() {
    final store = context.getInheritedWidgetOfExactType<WatchlistScope>()
        ?.notifier;
    if (store == null) return const [];
    return store.items.map((i) => '${i.market.code}:${i.symbol}').toList();
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() {
        _loading = false;
        _data = null;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final s = await _repo.autoWatchlistSuggestions(
        token,
        existing: _existingKeys(),
      );
      if (!mounted) return;
      setState(() {
        _data = s;
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

  Future<void> _applyAll() async {
    final token = _token;
    final data = _data;
    if (token == null || data == null || data.suggestions.isEmpty) return;
    setState(() => _busy = true);
    final store = context.getInheritedWidgetOfExactType<WatchlistScope>()
        ?.notifier;
    try {
      final res = await _repo.applyAutoWatchlist(
        token,
        items: data.suggestions,
        existing: _existingKeys(),
      );
      // Mirror applied names to the client-side watchlist.
      if (store != null) {
        for (final a in res.applied) {
          store.add(WatchlistItem(
            symbol: a.symbol,
            name: a.name,
            market: a.market,
            addedAt: DateTime.now(),
          ));
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${res.count} AI pick(s) to watchlist.')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  void _review() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _AutoWatchlistReviewPage(repository: widget.repository),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final count = _data?.suggestions.length ?? 0;
    return Column(
      key: const Key('auto_watchlist_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.auto_awesome, color: AppColors.seed, size: 20),
            const SizedBox(width: 8),
            const Text('Auto Watchlist AI',
                key: Key('auto_watchlist_title'),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.seed.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('AI PICK',
                  style: TextStyle(
                      color: AppColors.seed,
                      fontWeight: FontWeight.w800,
                      fontSize: 9)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          key: const Key('auto_watchlist_card'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildBody(count),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(int count) {
    if (_loading && _data == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            key: Key('auto_watchlist_loading'),
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (_token == null) {
      return const Text('Sign in to get daily AI watchlist picks.',
          style: TextStyle(color: Colors.grey));
    }
    if (_error) {
      return const Text('Auto Watchlist unavailable.',
          key: Key('auto_watchlist_error'),
          style: TextStyle(color: AppColors.down));
    }
    if (_data?.enabled == false) {
      return const Text('Auto Watchlist AI is turned off in settings.',
          style: TextStyle(color: Colors.grey));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          count == 0
              ? "No new picks today — you're all caught up."
              : '$count new pick(s) suggested today.',
          key: const Key('auto_watchlist_count'),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        if (count > 0) ...[
          const SizedBox(height: 4),
          Text(
            'Top: ${_data!.suggestions.first.market.flag} '
            '${_data!.suggestions.first.symbol} '
            '(score ${_data!.suggestions.first.score.toStringAsFixed(0)})',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('auto_watchlist_apply_all'),
                onPressed: (_busy || count == 0) ? null : _applyAll,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.playlist_add_check, size: 18),
                label: const Text('Apply All'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('auto_watchlist_review'),
                onPressed: _busy ? null : _review,
                icon: const Icon(Icons.reviews_outlined, size: 18),
                label: const Text('Review'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Full-screen "AI Suggestions" review: Add / Ignore each, or Add All.
class _AutoWatchlistReviewPage extends StatefulWidget {
  const _AutoWatchlistReviewPage({this.repository});
  final StockRepository? repository;

  @override
  State<_AutoWatchlistReviewPage> createState() =>
      _AutoWatchlistReviewPageState();
}

class _AutoWatchlistReviewPageState extends State<_AutoWatchlistReviewPage> {
  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  bool _loading = true;
  List<AutoWatchlistSuggestion> _items = const [];
  final Set<String> _ignored = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  List<String> _existingKeys() {
    final store = context.getInheritedWidgetOfExactType<WatchlistScope>()
        ?.notifier;
    if (store == null) return const [];
    return store.items.map((i) => '${i.market.code}:${i.symbol}').toList();
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() {
        _loading = false;
        _items = const [];
      });
      return;
    }
    try {
      final s = await _repo.autoWatchlistSuggestions(
        token,
        existing: _existingKeys(),
      );
      if (!mounted) return;
      setState(() {
        _items = s.suggestions;
        _loading = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _add(AutoWatchlistSuggestion s) async {
    final token = _token;
    if (token == null) return;
    final store = context.getInheritedWidgetOfExactType<WatchlistScope>()
        ?.notifier;
    try {
      await _repo.applyAutoWatchlist(
        token,
        items: [s],
        existing: _existingKeys(),
      );
      store?.add(WatchlistItem(
        symbol: s.symbol,
        name: s.name,
        market: s.market,
        addedAt: DateTime.now(),
      ));
    } on ApiException {
      // best-effort
    }
    if (!mounted) return;
    setState(() => _items = _items.where((x) => x.symbol != s.symbol).toList());
  }

  void _ignore(AutoWatchlistSuggestion s) {
    setState(() {
      _ignored.add('${s.market.code}:${s.symbol}');
      _items = _items.where((x) => x.symbol != s.symbol).toList();
    });
  }

  Future<void> _addAll() async {
    final token = _token;
    if (token == null || _items.isEmpty) return;
    final store = context.getInheritedWidgetOfExactType<WatchlistScope>()
        ?.notifier;
    try {
      final res = await _repo.applyAutoWatchlist(
        token,
        items: _items,
        existing: _existingKeys(),
      );
      if (store != null) {
        for (final a in res.applied) {
          store.add(WatchlistItem(
            symbol: a.symbol,
            name: a.name,
            market: a.market,
            addedAt: DateTime.now(),
          ));
        }
      }
    } on ApiException {
      // best-effort
    }
    if (!mounted) return;
    setState(() => _items = const []);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Suggestions',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (_items.isNotEmpty)
            TextButton(
              key: const Key('ai_suggestions_add_all'),
              onPressed: _addAll,
              child: const Text('Add All'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Text("No suggestions right now.",
                      key: Key('ai_suggestions_empty'),
                      style: TextStyle(color: Colors.grey)),
                )
              : ListView.separated(
                  key: const Key('ai_suggestions_list'),
                  padding: const EdgeInsets.all(12),
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final s = _items[i];
                    return Card(
                      key: Key('ai_suggestion_${s.symbol}'),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text('${s.market.flag} ${s.symbol}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15)),
                                const SizedBox(width: 8),
                                _badge('AI PICK', AppColors.seed),
                                if (s.owned) ...[
                                  const SizedBox(width: 6),
                                  _badge('OWNED', Colors.grey),
                                ],
                                const Spacer(),
                                Text('Score ${s.score.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.up)),
                              ],
                            ),
                            if (s.reason.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(s.reason,
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.black54)),
                            ],
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton(
                                    key: Key('ai_suggestion_add_${s.symbol}'),
                                    onPressed: () => _add(s),
                                    child: const Text('Add'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton(
                                    key:
                                        Key('ai_suggestion_ignore_${s.symbol}'),
                                    onPressed: () => _ignore(s),
                                    child: const Text('Ignore'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 9)),
      );
}
