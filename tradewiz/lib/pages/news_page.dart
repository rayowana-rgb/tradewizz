import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/news.dart';
import '../repositories/stock_repository.dart';
import '../services/repository_scope.dart';
import '../theme.dart';
import '../theme_tradewizz.dart';

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
      return const Center(
        key: Key('news_loading'),
        child: CircularProgressIndicator(),
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
    return ListView.separated(
      key: const Key('news_list'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _data.items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
      itemBuilder: (context, i) =>
          _NewsTile(item: _data.items[i], onTap: () => _open(_data.items[i])),
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
