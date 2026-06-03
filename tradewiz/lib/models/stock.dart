import 'market.dart';

/// A single stock / ticker.
class Stock {
  const Stock({
    required this.ticker,
    required this.name,
    required this.market,
    required this.price,
    required this.changePercent,
  });

  final String ticker;
  final String name;
  final Market market;
  final double price;
  final double changePercent;

  bool get isUp => changePercent >= 0;
}

/// Placeholder sample data used until a real data source is wired in.
const List<Stock> sampleStocks = [
  Stock(ticker: 'BBCA', name: 'Bank Central Asia', market: Market.idx, price: 9850, changePercent: 1.24),
  Stock(ticker: 'TLKM', name: 'Telkom Indonesia', market: Market.idx, price: 3120, changePercent: -0.63),
  Stock(ticker: 'GOTO', name: 'GoTo Gojek Tokopedia', market: Market.idx, price: 58, changePercent: 3.57),
  Stock(ticker: '0700', name: 'Tencent Holdings', market: Market.hkex, price: 412.6, changePercent: 0.88),
  Stock(ticker: '9988', name: 'Alibaba Group', market: Market.hkex, price: 78.2, changePercent: -1.12),
  Stock(ticker: '005930', name: 'Samsung Electronics', market: Market.kospi, price: 81500, changePercent: 2.01),
  Stock(ticker: '000660', name: 'SK Hynix', market: Market.kospi, price: 198000, changePercent: -0.45),
  Stock(ticker: '247540', name: 'EcoPro BM', market: Market.kosdaq, price: 142300, changePercent: 4.18),
];
