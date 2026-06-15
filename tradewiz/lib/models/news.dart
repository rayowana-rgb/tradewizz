/// Global market news models (mirrors backend `app.news.models`).
class NewsItem {
  const NewsItem({
    required this.id,
    required this.title,
    this.summary = '',
    this.publisher = '',
    this.url = '',
    this.publishedAt = '',
    this.thumbnail,
    this.relatedSymbols = const [],
  });

  final String id;
  final String title;
  final String summary;
  final String publisher;
  final String url;
  final String publishedAt; // ISO-8601 (UTC), may be empty
  final String? thumbnail;
  final List<String> relatedSymbols;

  factory NewsItem.fromJson(Map<String, dynamic> j) => NewsItem(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        summary: (j['summary'] ?? '').toString(),
        publisher: (j['publisher'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        publishedAt: (j['published_at'] ?? '').toString(),
        thumbnail: (j['thumbnail'] as String?),
        relatedSymbols: ((j['related_symbols'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  /// Parsed timestamp, or null when missing/invalid.
  DateTime? get publishedAtDate => DateTime.tryParse(publishedAt)?.toLocal();
}

class NewsFeed {
  const NewsFeed({
    this.scope = 'GLOBAL',
    this.generatedAt = '',
    this.items = const [],
    this.cached = false,
    this.fallback = false,
  });

  final String scope;
  final String generatedAt;
  final List<NewsItem> items;
  final bool cached;
  final bool fallback;

  factory NewsFeed.fromJson(Map<String, dynamic> j) => NewsFeed(
        scope: (j['scope'] ?? 'GLOBAL').toString(),
        generatedAt: (j['generated_at'] ?? '').toString(),
        items: ((j['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => NewsItem.fromJson(e.cast<String, dynamic>()))
            .toList(),
        cached: j['cached'] == true,
        fallback: j['fallback'] == true,
      );
}
