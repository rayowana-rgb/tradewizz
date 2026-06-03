/// Supported stock markets in TradeWiz.
enum Market {
  idx(code: 'IDX', name: 'Indonesia Stock Exchange', flag: '🇮🇩', currency: 'IDR'),
  hkex(code: 'HKEX', name: 'Hong Kong Stock Exchange', flag: '🇭🇰', currency: 'HKD'),
  kospi(code: 'KOSPI', name: 'Korea Composite Stock Price Index', flag: '🇰🇷', currency: 'KRW'),
  kosdaq(code: 'KOSDAQ', name: 'Korean Securities Dealers Automated Quotations', flag: '🇰🇷', currency: 'KRW');

  const Market({
    required this.code,
    required this.name,
    required this.flag,
    required this.currency,
  });

  final String code;
  final String name;
  final String flag;
  final String currency;
}
