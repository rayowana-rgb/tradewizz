import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/news.dart';
import '../repositories/stock_repository.dart';
import '../services/repository_scope.dart';
import '../theme.dart';
import '../theme_tradewizz.dart';
import '../widgets/ds/ds.dart';

/// Global market news — world-wide headlines (US/EU/Asia indices, commodities,
/// crypto, FX) sourced via the backend's yfinance aggregator. Research only.
class NewsPage extends StatefulWidget {
  const NewsPage({super.key, this.repository});

  final StockRepository? repository;

  @override
  State<NewsPage> createState() => _NewsPageState();
}

class _NewsPageState extends State<NewsPage> {
  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  bool _loading = true;
  bool _error = false;
  NewsFeed _data = const NewsFeed();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) _load();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() => _loading = _data.items.isEmpty);
    try {
      final feed = await _repo.news(forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() {
        _data = feed;
        _loading = false;
        _error = false;
      });
    } catch (_) {
      // Keep any items we already have; only flag error when there's nothing.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _data.items.isEmpty;
      });
    }
  }

  Future<void> _open(NewsItem item) async {
    if (item.url.isEmpty) return;
    final uri = Uri.tryParse(item.url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the article.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TWColors.bgBase,
      appBar: AppBar(
        backgroundColor: TWColors.bgBase,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('World Market News',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: TWColors.textPrimary)),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(forceRefresh: true),
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const TWBusyIndicator(
        key: Key('news_loading'),
        title: 'Loading news…',
        subtitle: 'Fetching the latest market headlines.',
      );
    }
    if (_error) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text('News unavailable. Pull to retry.',
                  key: Key('news_error'),
                  style: TextStyle(color: AppColors.down)),
            ),
          ),
        ],
      );
    }
    if (_data.items.isEmpty) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text('No headlines right now.',
                  key: Key('news_empty'),
                  style: TextStyle(color: TWColors.textTertiary)),
            ),
          ),
        ],
      );
    }
    return ListView(
      key: const Key('news_list'),
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (_data.topics.isNotEmpty) _TopicsPanel(topics: _data.topics),
        for (final item in _data.items) ...[
          _NewsTile(item: item, onTap: () => _open(item)),
          const Divider(height: 1, indent: 16),
        ],
      ],
    );
  }
}

/// "What the world is talking about" — rule-based theme summary shown above
/// the headline list. At least 3 themes per the backend contract.
class _TopicsPanel extends StatelessWidget {
  const _TopicsPanel({required this.topics});
  final List<NewsTopic> topics;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('news_topics_panel'),
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: TWColors.heroBlueGradient,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.travel_explore, size: 18, color: Colors.white),
              SizedBox(width: 8),
              Expanded(
                child: Text('WHAT THE WORLD IS TALKING ABOUT',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < topics.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _TopicRow(topic: topics[i]),
          ],
        ],
      ),
    );
  }
}

class _TopicRow extends StatelessWidget {
  const _TopicRow({required this.topic});
  final NewsTopic topic;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 5, right: 8),
          child: Icon(Icons.circle, size: 6, color: Colors.white70),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(topic.label.toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4)),
                  ),
                  if (topic.articleCount > 1) ...[
                    const SizedBox(width: 6),
                    Text('${topic.articleCount} stories',
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 11)),
                  ],
                ],
              ),
              if (topic.headline.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(topic.headline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          height: 1.25,
                          fontWeight: FontWeight.w500)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NewsTile extends StatelessWidget {
  const _NewsTile({required this.item, required this.onTap});
  final NewsItem item;
  final VoidCallback onTap;

  String get _meta {
    final parts = <String>[];
    if (item.publisher.isNotEmpty) parts.add(item.publisher);
    final dt = item.publishedAtDate;
    if (dt != null) parts.add(_ago(dt));
    return parts.join(' · ');
  }

  static String _ago(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('news_item_${item.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: const Icon(Icons.public, color: TWColors.accentBright),
      title: Text(item.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: TWColors.textPrimary,
              height: 1.25)),
      subtitle: _meta.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_meta,
                  style: const TextStyle(
                      fontSize: 12, color: TWColors.textTertiary)),
            ),
      trailing: const Icon(Icons.open_in_new,
          size: 18, color: TWColors.textTertiary),
      onTap: onTap,
    );
  }
}
