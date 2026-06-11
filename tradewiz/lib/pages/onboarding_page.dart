import 'package:flutter/material.dart';

import '../home/activation_scope.dart';
import '../models/market.dart';
import '../models/stock.dart';
import '../models/user_profile_prefs.dart';
import '../models/watchlist_item.dart';
import '../services/user_prefs_scope.dart';
import '../services/watchlist_scope.dart';
import '../theme_tradewizz.dart';

/// Phase A — Onboarding Personalization.
///
/// A 5-screen flow that delivers value within the first session: pick markets,
/// pick interests, build a starter watchlist (>=3), then generate the first
/// personalized Morning Brief. Selections are stored locally (and synced
/// best-effort to the backend) via [UserPrefsScope]; the watchlist is written
/// to the shared [WatchlistScope]. Completion drops the user on the new Home.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, this.onDone});

  /// Called once onboarding completes (host swaps to the Home shell).
  final VoidCallback? onDone;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _controller = PageController();
  int _page = 0;

  // Selections.
  final Set<Market> _markets = {};
  final Set<Interest> _interests = {};
  final List<WatchlistItem> _picked = [];
  bool _emittedStart = false;

  // Markets offered (Phase A screen 2). Korea => KOSPI.
  static const List<Market> _offered = [
    Market.idx,
    Market.us,
    Market.japan,
    Market.india,
    Market.singapore,
    Market.vietnam,
    Market.hkex,
    Market.kospi,
  ];

  @override
  void initState() {
    super.initState();
    // Default-select IDX so the user can always proceed.
    _markets.add(Market.idx);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _maybeEmitStart() {
    if (_emittedStart) return;
    _emittedStart = true;
    // Defer past the current build frame: emitting now would notify listeners
    // during build.
    final metrics = ActivationScope.maybeOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      metrics?.onboardingStarted();
    });
  }

  void _next() {
    if (_page < 4) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _finish() async {
    final prefs = UserPrefsScope.maybeOf(context);
    final watchlist = WatchlistScope.maybeOf(context);
    final metrics = ActivationScope.maybeOf(context);

    // Persist picks to the shared watchlist.
    for (final item in _picked) {
      watchlist?.add(item);
    }
    if (_picked.isNotEmpty) {
      metrics?.firstWatchlistCreated(_picked.length);
    }

    await prefs?.setMarkets(_markets.toList());
    await prefs?.setInterests(_interests.toList());
    await prefs?.completeOnboarding();

    metrics?.onboardingCompleted(
      markets: _markets.length,
      interests: _interests.length,
    );
    metrics?.firstValueDelivered(); // first brief generated => Time To Value

    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    _maybeEmitStart();
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _ProgressDots(current: _page, total: 5),
            Expanded(
              child: PageView(
                key: const Key('onboarding_pageview'),
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  _WelcomeScreen(onStart: _next),
                  _MarketsScreen(
                    selected: _markets,
                    offered: _offered,
                    onToggle: (m) => setState(() {
                      _markets.contains(m)
                          ? _markets.remove(m)
                          : _markets.add(m);
                    }),
                    onNext: _markets.isEmpty ? null : _next,
                  ),
                  _InterestsScreen(
                    selected: _interests,
                    onToggle: (i) => setState(() {
                      _interests.contains(i)
                          ? _interests.remove(i)
                          : _interests.add(i);
                    }),
                    onNext: _next,
                  ),
                  _WatchlistScreen(
                    picked: _picked,
                    onChanged: () => setState(() {}),
                    onNext: _picked.length >= 3 ? _next : null,
                  ),
                  _GenerateScreen(
                    markets: _markets.toList(),
                    interests: _interests.toList(),
                    symbols: _picked.map((e) => e.symbol).toList(),
                    onDone: _finish,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// Screen 1 — Welcome
// =========================================================================
class _WelcomeScreen extends StatelessWidget {
  const _WelcomeScreen({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.auto_awesome, size: 56, color: TWColors.accent),
          const SizedBox(height: 24),
          Text('Welcome to TradeWizz',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          const Text(
            'Your personal AI investing advisor.',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Get a personalized Morning Brief every market open.',
            style: TWType.bodySm.copyWith(color: TWColors.textTertiary),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('onboarding_get_started'),
              onPressed: onStart,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Get Started',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// Screen 2 — Markets
// =========================================================================
class _MarketsScreen extends StatelessWidget {
  const _MarketsScreen({
    required this.selected,
    required this.offered,
    required this.onToggle,
    required this.onNext,
  });
  final Set<Market> selected;
  final List<Market> offered;
  final ValueChanged<Market> onToggle;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return _StepScaffold(
      title: 'Choose Markets',
      subtitle: 'Select the markets you want to follow.',
      onNext: onNext,
      nextLabel: 'Continue',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final m in offered)
            FilterChip(
              key: Key('onboarding_market_${m.code}'),
              selected: selected.contains(m),
              onSelected: (_) => onToggle(m),
              label: Text('${m.flag}  ${m.code}'),
            ),
        ],
      ),
    );
  }
}

// =========================================================================
// Screen 3 — Interests
// =========================================================================
class _InterestsScreen extends StatelessWidget {
  const _InterestsScreen({
    required this.selected,
    required this.onToggle,
    required this.onNext,
  });
  final Set<Interest> selected;
  final ValueChanged<Interest> onToggle;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return _StepScaffold(
      title: 'What interests you?',
      subtitle: 'We tune your ideas to match. Pick any that fit.',
      onNext: onNext,
      nextLabel: 'Continue',
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final i in Interest.values)
            FilterChip(
              key: Key('onboarding_interest_${i.code}'),
              selected: selected.contains(i),
              onSelected: (_) => onToggle(i),
              label: Text(i.label),
            ),
        ],
      ),
    );
  }
}

// =========================================================================
// Screen 4 — Build watchlist (>=3 symbols)
// =========================================================================
class _WatchlistScreen extends StatefulWidget {
  const _WatchlistScreen({
    required this.picked,
    required this.onChanged,
    required this.onNext,
  });
  final List<WatchlistItem> picked;
  final VoidCallback onChanged;
  final VoidCallback? onNext;

  @override
  State<_WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<_WatchlistScreen> {
  final _query = TextEditingController();

  List<Stock> get _results {
    final q = _query.text.trim().toUpperCase();
    if (q.isEmpty) return sampleStocks.take(8).toList();
    return sampleStocks
        .where((s) =>
            s.ticker.toUpperCase().contains(q) ||
            s.name.toUpperCase().contains(q))
        .take(12)
        .toList();
  }

  void _add(Stock s) {
    if (widget.picked.any(
        (i) => i.symbol == s.ticker.toUpperCase() && i.market == s.market)) {
      return;
    }
    widget.picked.add(WatchlistItem(
      symbol: s.ticker.toUpperCase(),
      name: s.name,
      market: s.market,
      addedAt: DateTime.now(),
    ));
    widget.onChanged();
  }

  void _removeAt(int i) {
    widget.picked.removeAt(i);
    widget.onChanged();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _StepScaffold(
      title: 'Build Your Watchlist',
      subtitle: 'Add at least 3 symbols (${widget.picked.length}/3).',
      onNext: widget.onNext,
      nextLabel: 'Continue',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.picked.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < widget.picked.length; i++)
                  InputChip(
                    key: Key('onboarding_picked_${widget.picked[i].symbol}'),
                    label: Text(widget.picked[i].symbol),
                    onDeleted: () => _removeAt(i),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('onboarding_symbol_search'),
            controller: _query,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search e.g. BBCA, AAPL, NVDA',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 220,
            child: ListView(
              children: [
                for (final s in _results)
                  ListTile(
                    key: Key('onboarding_result_${s.ticker}'),
                    dense: true,
                    title: Text('${s.ticker}  ·  ${s.market.code}'),
                    subtitle: Text(s.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.add_circle_outline),
                    onTap: () => _add(s),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// Screen 5 — Generate first brief
// =========================================================================
class _GenerateScreen extends StatefulWidget {
  const _GenerateScreen({
    required this.markets,
    required this.interests,
    required this.symbols,
    required this.onDone,
  });
  final List<Market> markets;
  final List<Interest> interests;
  final List<String> symbols;
  final Future<void> Function() onDone;

  @override
  State<_GenerateScreen> createState() => _GenerateScreenState();
}

class _GenerateScreenState extends State<_GenerateScreen> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // Simulate the brief assembling, then reveal the finish CTA. Uses the
    // user's selections — the real brief is fetched on Home from the existing
    // morning-brief engine (unchanged).
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final marketLabel = widget.markets.isEmpty
        ? 'your markets'
        : widget.markets.map((m) => m.code).join(', ');
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_ready) ...[
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 24),
            const Center(
              child: Text('Creating your personalized AI Brief…',
                  key: Key('onboarding_generating'),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ] else ...[
            const Icon(Icons.check_circle, size: 52, color: TWColors.up),
            const SizedBox(height: 20),
            Text('Your Morning Brief is ready',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Text('Markets: $marketLabel',
                style: TWType.bodySm.copyWith(color: TWColors.textTertiary)),
            Text('Watchlist: ${widget.symbols.length} symbols',
                style: TWType.bodySm.copyWith(color: TWColors.textTertiary)),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('onboarding_finish'),
                onPressed: widget.onDone,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('See my Brief',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =========================================================================
// Shared step scaffold + progress dots
// =========================================================================
class _StepScaffold extends StatelessWidget {
  const _StepScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
    required this.onNext,
    this.nextLabel = 'Next',
  });
  final String title;
  final String subtitle;
  final Widget child;
  final VoidCallback? onNext;
  final String nextLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(subtitle,
              style: TWType.bodySm.copyWith(color: TWColors.textTertiary)),
          const SizedBox(height: 20),
          Expanded(child: SingleChildScrollView(child: child)),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('onboarding_next'),
              onPressed: onNext,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(nextLabel,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressDots extends StatelessWidget {
  const _ProgressDots({required this.current, required this.total});
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < total; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: i == current ? 22 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i <= current ? TWColors.accent : TWColors.hairlineTop,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }
}
