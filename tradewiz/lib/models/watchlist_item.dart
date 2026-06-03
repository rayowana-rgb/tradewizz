import 'market.dart';

/// A persisted watchlist entry.
class WatchlistItem {
  const WatchlistItem({
    required this.symbol,
    required this.name,
    required this.market,
    this.addedAt,
  });

  final String symbol;
  final String name;
  final Market market;
  final DateTime? addedAt;

  factory WatchlistItem.fromJson(Map<String, dynamic> json) {
    return WatchlistItem(
      symbol: json['symbol'] as String,
      name: json['name'] as String? ?? '',
      market: Market.values.firstWhere(
        (m) => m.code == (json['market'] as String?),
        orElse: () => Market.idx,
      ),
      addedAt: DateTime.tryParse(json['added_at'] as String? ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'name': name,
        'market': market.code,
        'added_at': (addedAt ?? DateTime.now()).toIso8601String(),
      };

  WatchlistItem copyWith({String? name, DateTime? addedAt}) => WatchlistItem(
        symbol: symbol,
        name: name ?? this.name,
        market: market,
        addedAt: addedAt ?? this.addedAt,
      );
}
