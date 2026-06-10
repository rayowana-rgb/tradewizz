import 'package:flutter/material.dart';

import '../models/market.dart';
import '../models/screener_result.dart';
import '../models/watchlist_item.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/repository_scope.dart';
import '../services/watchlist_scope.dart';
import '../theme.dart';
import '../widgets/auto_watchlist.dart';
import 'ai_analysis_page.dart';

/// Phase 10A — Watchlist redesign.
///
/// A real, daily-habit watchlist (not a list of names):
///   • Search bar (ticker or company name) with manual "Add to Watchlist".
///   • Two clearly separated sections: YOUR WATCHLIST and AI WATCHLIST.
///   • Each row shows latest price, daily %, Final Score, signal + an AI alert
///     and a tiny sparkline — all derived from the EXISTING screener result
///     (no new API, no engine changes).
class WatchlistPage extends StatefulWidget {
  const WatchlistPage({super.key, required this.market, this.repository});

  final Market market;
  final StockRepository? repository;

  @override
  State<WatchlistPage> createState() => _WatchlistPageState();
}

class _WatchlistPageState extends State<WatchlistPage> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  // symbol -> screener match for the active market (price/score/signal/tags).
  Map<String, ScreenerMatch> _quotes = const {};
  bool _quotesLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_quotesLoaded) _loadQuotes();
  }

  @override
  void didUpdateWidget(covariant WatchlistPage old) {
    super.didUpdateWidget(old);
    if (old.market != widget.market) {
      _quotes = const {};
      _quotesLoaded = false;
      _loadQuotes();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Enrich rows using the existing `/screen/{market}` result (broad limit so
  /// most watchlist names are present). Best-effort: failures leave rows
  /// showing names only, never an error wall.
  Future<void> _loadQuotes() async {
    try {
      final res = await _repo.screen(widget.market, limit: 200);
      if (!mounted) return;
      setState(() {
        _quotes = {for (final m in res.data.matches) m.symbol: m};
        _quotesLoaded = true;
      });
    } on ApiException {
      if (mounted) setState(() => _quotesLoaded = true);
    } catch (_) {
      if (mounted) setState(() => _quotesLoaded = true);
    }
  }

  void _open(WatchlistItem item) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AnalysisDetailPage(
        symbol: item.symbol,
        market: item.market,
        repository: widget.repository,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final store = WatchlistScope.of(context); // rebuilds on changes
    final items = store.forMarket(widget.market);
    final q = _query.trim().toUpperCase();

    // Search results: screener universe filtered by ticker / company name,
    // excluding names already in the watchlist.
    final searchHits = q.isEmpty
        ? const <ScreenerMatch>[]
        : (_quotes.values
            .where((m) =>
                (m.symbol.toUpperCase().contains(q) ||
                    m.name.toUpperCase().contains(q)) &&
                !store.contains(m.symbol, widget.market))
            .toList()
          ..sort((a, b) =>
              b.effectiveFinalScore.compareTo(a.effectiveFinalScore)))
            .take(12)
            .toList();

    return ListView(
      key: const Key('watchlist_list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // --- Search + manual add -------------------------------------------
        _SearchBar(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _query = v),
          onClear: () {
            _searchCtrl.clear();
            setState(() => _query = '');
          },
        ),
        if (q.isNotEmpty) ...[
          const SizedBox(height: 8),
          _SearchResults(
            hits: searchHits,
            loading: !_quotesLoaded,
            market: widget.market,
            onAdd: (m) {
              store.add(WatchlistItem(
                symbol: m.symbol,
                name: m.name,
                market: widget.market,
                addedAt: DateTime.now(),
              ));
              _searchCtrl.clear();
              setState(() => _query = '');
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${m.symbol} added to your watchlist.')),
              );
            },
          ),
          const SizedBox(height: 16),
        ],

        // --- YOUR WATCHLIST ------------------------------------------------
        const _SectionHeader(
          icon: Icons.star_rounded,
          title: 'Your Watchlist',
          color: AppColors.seed,
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          _EmptyYourWatchlist(market: widget.market)
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  Dismissible(
                    key: ValueKey('${items[i].market.code}:${items[i].symbol}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      decoration: BoxDecoration(
                        color: AppColors.down.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child:
                          const Icon(Icons.delete_outline, color: AppColors.down),
                    ),
                    onDismissed: (_) =>
                        store.remove(items[i].symbol, items[i].market),
                    child: _WatchRow(
                      item: items[i],
                      match: _quotes[items[i].symbol],
                      onTap: () => _open(items[i]),
                    ),
                  ),
                  if (i != items.length - 1)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                ],
              ],
            ),
          ),
        if (items.isNotEmpty) ...[
          const SizedBox(height: 6),
          Center(
            child: Text(
              'Swipe left to remove · ${items.length} in watchlist',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
        const SizedBox(height: 20),

        // --- AI WATCHLIST --------------------------------------------------
        const _SectionHeader(
          icon: Icons.auto_awesome,
          title: 'AI Watchlist',
          color: AppColors.seed,
          trailing: 'AI PICK',
        ),
        const SizedBox(height: 8),
        AutoWatchlistCard(repository: widget.repository),
      ],
    );
  }
}

// =========================================================================
// Search
// =========================================================================
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const Key('watchlist_search'),
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search symbol or company…',
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                key: const Key('watchlist_search_clear'),
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClear,
              ),
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
      ),
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.hits,
    required this.loading,
    required this.market,
    required this.onAdd,
  });
  final List<ScreenerMatch> hits;
  final bool loading;
  final Market market;
  final ValueChanged<ScreenerMatch> onAdd;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
          ),
        ),
      );
    }
    if (hits.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No matches in this market.',
              key: Key('watchlist_search_empty'),
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return Card(
      key: const Key('watchlist_search_results'),
      child: Column(
        children: [
          for (var i = 0; i < hits.length; i++) ...[
            ListTile(
              key: Key('watchlist_search_add_${hits[i].symbol}'),
              dense: true,
              leading: _Avatar(symbol: hits[i].symbol),
              title: Text(hits[i].symbol,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                hits[i].name.isEmpty ? market.name : hits[i].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: FilledButton.tonalIcon(
                onPressed: () => onAdd(hits[i]),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
            ),
            if (i != hits.length - 1)
              const Divider(height: 1, indent: 16, endIndent: 16),
          ],
        ],
      ),
    );
  }
}

// =========================================================================
// Section header
// =========================================================================
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.color,
    this.trailing,
  });
  final IconData icon;
  final String title;
  final Color color;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(trailing!,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w800, fontSize: 9)),
          ),
        ],
      ],
    );
  }
}

// =========================================================================
// Watchlist row (enriched)
// =========================================================================
class _WatchRow extends StatelessWidget {
  const _WatchRow({required this.item, required this.match, this.onTap});
  final WatchlistItem item;
  final ScreenerMatch? match;
  final VoidCallback? onTap;

  /// Derive a short, human AI alert from the row's category tags.
  String? _aiAlert(ScreenerMatch m) {
    final tags = m.exploreTags;
    if (tags.contains('Silent Accumulation')) return 'Accumulation detected';
    if (tags.contains('Accumulation')) return 'Accumulation detected';
    if (tags.contains('Strong OBV') || tags.contains('Strong CMF')) {
      return 'Volume breakout';
    }
    if (tags.contains('ARA Hunter')) return 'Momentum surge';
    if (tags.contains('Turnaround Multibagger')) return 'Turnaround setup';
    if (tags.contains('Strong ADX')) return 'Trend strengthening';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final m = match;
    final up = (m?.changePercent ?? 0) >= 0;
    final changeColor = up ? AppColors.up : AppColors.down;
    final alert = m == null ? null : _aiAlert(m);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Avatar(symbol: item.symbol),
            const SizedBox(width: 12),
            // Symbol + name + AI alert.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.symbol,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                  Text(
                    item.name.isEmpty ? item.market.name : item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  if (alert != null) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.bolt,
                            size: 13, color: Colors.orange),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text('AI Alert: $alert',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.orange)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Optional sparkline (synthesized from price+%; no new API).
            if (m != null) ...[
              SizedBox(
                width: 44,
                height: 26,
                child: CustomPaint(
                  painter: _SparklinePainter(up: up, color: changeColor),
                ),
              ),
              const SizedBox(width: 10),
            ],
            // Price / % / score / signal.
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (m != null) ...[
                  Text(_price(m.price),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14)),
                  Text(
                    '${up ? '+' : ''}${m.changePercent.toStringAsFixed(1)}%',
                    style: TextStyle(
                        color: changeColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  _ScoreSignal(
                    score: m.effectiveFinalScore,
                    signal: m.signal,
                  ),
                ] else
                  Text('${item.market.flag} ${item.market.code}',
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _price(double v) {
    final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
    return s;
  }
}

class _ScoreSignal extends StatelessWidget {
  const _ScoreSignal({required this.score, required this.signal});
  final double score;
  final String signal;

  @override
  Widget build(BuildContext context) {
    final s = signal.toUpperCase();
    final color = s.contains('BUY')
        ? AppColors.up
        : (s.contains('SELL') ? AppColors.down : Colors.orange);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Score ${score.toStringAsFixed(0)}',
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.seed)),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(s,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w800, fontSize: 10)),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.symbol});
  final String symbol;
  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: AppColors.seed.withValues(alpha: 0.10),
      child: Text(
        symbol.characters.take(2).toString().toUpperCase(),
        style: const TextStyle(
            fontWeight: FontWeight.w800, fontSize: 12, color: AppColors.seed),
      ),
    );
  }
}

/// A tiny deterministic sparkline. It conveys trend direction (up/down) using
/// the row's daily change; it does not invent price history or call any API.
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.up, required this.color});
  final bool up;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    // A gentle, monotonic-ish curve in the trend direction.
    final ys = up
        ? const [0.75, 0.65, 0.7, 0.5, 0.45, 0.3, 0.2]
        : const [0.25, 0.35, 0.3, 0.5, 0.55, 0.7, 0.8];
    final path = Path();
    for (var i = 0; i < ys.length; i++) {
      final x = size.width * (i / (ys.length - 1));
      final y = size.height * ys[i];
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.up != up || old.color != color;
}

// =========================================================================
// Empty state (Your Watchlist)
// =========================================================================
class _EmptyYourWatchlist extends StatelessWidget {
  const _EmptyYourWatchlist({required this.market});
  final Market market;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('watchlist_empty_your'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          children: [
            const Icon(Icons.search, size: 40, color: Colors.grey),
            const SizedBox(height: 10),
            Text('Your ${market.code} watchlist is empty',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              'Search above to add stocks you want to track.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
