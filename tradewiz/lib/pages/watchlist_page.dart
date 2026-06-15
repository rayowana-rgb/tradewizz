import 'package:flutter/material.dart';

import '../models/market.dart';
import '../models/screener_result.dart';
import '../models/watchlist_item.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/repository_scope.dart';
import '../services/watchlist_scope.dart';
import '../theme_tradewizz.dart';
import '../widgets/auto_watchlist.dart';
import '../widgets/broker_open_sheet.dart';
import '../widgets/ds/ds.dart';
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

    final bottomInset = MediaQuery.of(context).padding.bottom;
    return TWScaffoldBackground(
      child: ListView(
        key: const Key('watchlist_list'),
        padding: EdgeInsets.fromLTRB(
            TWSpace.lg, TWSpace.sm, TWSpace.lg, bottomInset + TWSpace.xxxxl),
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
        // Balance the heading: equal breathing room above and below it.
        const SizedBox(height: TWSpace.md),
        const _SectionHeader(
          icon: Icons.star_rounded,
          title: 'Your Watchlist',
          color: TWColors.accentBright,
        ),
        const SizedBox(height: TWSpace.md),
        if (items.isEmpty)
          _EmptyYourWatchlist(market: widget.market)
        else
          Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                Dismissible(
                  key: ValueKey('${items[i].market.code}:${items[i].symbol}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: TWSpace.xxl),
                    decoration: BoxDecoration(
                      color: TWColors.downSoft,
                      borderRadius: TWRadius.rCard,
                    ),
                    child: const Icon(Icons.delete_outline_rounded,
                        color: TWColors.down),
                  ),
                  onDismissed: (_) =>
                      store.remove(items[i].symbol, items[i].market),
                  child: TWFloatingCard(
                    padding: EdgeInsets.zero,
                    onTap: () => _open(items[i]),
                    child: _WatchRow(
                      item: items[i],
                      match: _quotes[items[i].symbol],
                    ),
                  ),
                ),
                if (i != items.length - 1)
                  const SizedBox(height: TWSpace.md),
              ],
            ],
          ),
        if (items.isNotEmpty) ...[
          const SizedBox(height: TWSpace.md),
          Center(
            child: Text(
              'Swipe left to remove \u00b7 ${items.length} in watchlist',
              style: TWType.caption,
            ),
          ),
        ],
        const SizedBox(height: TWSpace.xxl),

        // --- AI WATCHLIST --------------------------------------------------
        const _SectionHeader(
          icon: Icons.auto_awesome,
          title: 'AI Watchlist',
          color: TWColors.accentBright,
          trailing: 'AI PICK',
        ),
        const SizedBox(height: TWSpace.md),
        AutoWatchlistCard(repository: widget.repository),
        ],
      ),
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
      style: TWType.body.copyWith(color: TWColors.textPrimary),
      cursorColor: TWColors.accentBright,
      decoration: InputDecoration(
        hintText: 'Search symbol or company…',
        hintStyle: TWType.body.copyWith(color: TWColors.textTertiary),
        prefixIcon:
            const Icon(Icons.search, size: 20, color: TWColors.textTertiary),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                key: const Key('watchlist_search_clear'),
                icon: const Icon(Icons.close, size: 18,
                    color: TWColors.textTertiary),
                onPressed: onClear,
              ),
        isDense: true,
        filled: true,
        fillColor: TWColors.surfaceCard,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: TWSpace.lg, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: TWRadius.rButton,
          borderSide: const BorderSide(color: TWColors.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: TWRadius.rButton,
          borderSide: const BorderSide(color: TWColors.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: TWRadius.rButton,
          borderSide: const BorderSide(color: TWColors.accent, width: 1.4),
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
      return const TWFloatingCard(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: TWBusyIndicator(
            title: 'Searching…',
            size: 22,
            strokeWidth: 2.2,
            boxed: false,
          ),
        ),
      );
    }
    if (hits.isEmpty) {
      return TWFloatingCard(
        child: Text('No matches in this market.',
            key: const Key('watchlist_search_empty'),
            style: TWType.bodySm.copyWith(color: TWColors.textTertiary)),
      );
    }
    return TWFloatingCard(
      key: const Key('watchlist_search_results'),
      padding: const EdgeInsets.symmetric(vertical: TWSpace.sm),
      child: Column(
        children: [
          for (var i = 0; i < hits.length; i++)
            ListTile(
              key: Key('watchlist_search_add_${hits[i].symbol}'),
              dense: true,
              leading: _Avatar(symbol: hits[i].symbol),
              title: Text(hits[i].symbol, style: TWType.label),
              subtitle: Text(
                hits[i].name.isEmpty ? market.name : hits[i].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TWType.caption,
              ),
              trailing: TWGhostButton(
                label: 'Add',
                icon: Icons.add_rounded,
                expand: false,
                height: 38,
                onPressed: () => onAdd(hits[i]),
              ),
            ),
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
        const SizedBox(width: TWSpace.sm),
        Text(title, style: TWType.title3),
        if (trailing != null) ...[
          const SizedBox(width: TWSpace.sm),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: TWSpace.sm, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: TWRadius.rChip,
            ),
            child: Text(trailing!,
                style: TWType.overline.copyWith(color: color)),
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
  const _WatchRow({required this.item, required this.match});
  final WatchlistItem item;
  final ScreenerMatch? match;

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
    final changeColor = up ? TWColors.up : TWColors.down;
    final alert = m == null ? null : _aiAlert(m);

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.lg, vertical: TWSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _Avatar(symbol: item.symbol),
          const SizedBox(width: TWSpace.md),
          // Symbol + name + AI alert.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.symbol, style: TWType.label),
                Text(
                  item.name.isEmpty ? item.market.name : item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TWType.caption,
                ),
                if (alert != null) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(Icons.bolt_rounded,
                          size: 13, color: TWColors.warn),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text('AI Alert: $alert',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TWType.caption
                                .copyWith(color: TWColors.warn)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: TWSpace.sm),
          // Trend sparkline (synthesized from trend direction; no new API).
          if (m != null) ...[
            TWSparkline(
              points: up
                  ? const [0.2, 0.35, 0.3, 0.5, 0.55, 0.72, 0.85]
                  : const [0.85, 0.7, 0.74, 0.5, 0.45, 0.3, 0.18],
              up: up,
              width: 44,
              height: 26,
            ),
            const SizedBox(width: TWSpace.md),
          ],
          // Price / % / score / signal.
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m != null) ...[
                Text(_price(m.price),
                    style: TWType.tabular(TWType.label)
                        .copyWith(color: TWColors.textPrimary)),
                Text(
                  '${up ? '+' : ''}${m.changePercent.toStringAsFixed(1)}%',
                  style: TWType.tabular(TWType.caption)
                      .copyWith(color: changeColor),
                ),
                const SizedBox(height: TWSpace.xs),
                _ScoreSignal(
                  score: m.effectiveFinalScore,
                  signal: m.signal,
                ),
              ] else
                Text('${item.market.flag} ${item.market.code}',
                    style: TWType.caption),
            ],
          ),
          // Read-only broker hand-off for this watchlist symbol.
          OpenBrokerIconButton(
            symbol: item.symbol,
            market: item.market,
            source: 'watchlist',
            size: 18,
          ),
        ],
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Score ${score.toStringAsFixed(0)}',
            style: TWType.tabular(TWType.caption)
                .copyWith(color: TWColors.accentBright)),
        const SizedBox(width: TWSpace.sm),
        TWSignalPill(signal: signal),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.symbol});
  final String symbol;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: TWColors.accent.withValues(alpha: 0.16),
        shape: BoxShape.circle,
        border: Border.all(color: TWColors.hairlineTop),
      ),
      child: Text(
        symbol.characters.take(2).toString().toUpperCase(),
        style: TWType.label.copyWith(color: TWColors.accentBright),
      ),
    );
  }
}

// =========================================================================
// Empty state (Your Watchlist)
// =========================================================================
class _EmptyYourWatchlist extends StatelessWidget {
  const _EmptyYourWatchlist({required this.market});
  final Market market;

  @override
  Widget build(BuildContext context) {
    return TWEmptyState(
      key: const Key('watchlist_empty_your'),
      icon: Icons.search_rounded,
      title: 'Your ${market.code} watchlist is empty',
      body: 'Search above to add stocks you want to track.',
    );
  }
}
