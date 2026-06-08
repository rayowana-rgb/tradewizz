/// Supported stock markets in TradeWiz.
///
/// [tradableViaMoomoo] is the single source of truth for whether the broker
/// (Moomoo) Buy/Sell flow is offered for a market. It mirrors the backend
/// `symbol_map`: only HKEX is tradable today; IDX/KOSPI/KOSDAQ are not.
enum Market {
  idx(
    code: 'IDX',
    name: 'Indonesia Stock Exchange',
    flag: '🇮🇩',
    currency: 'IDR',
    yahooSuffix: '.JK',
    tradableViaMoomoo: false,
  ),
  hkex(
    code: 'HKEX',
    name: 'Hong Kong Stock Exchange',
    flag: '🇭🇰',
    currency: 'HKD',
    yahooSuffix: '.HK',
    tradableViaMoomoo: true,
  ),
  kospi(
    code: 'KOSPI',
    name: 'Korea Composite Stock Price Index',
    flag: '🇰🇷',
    currency: 'KRW',
    yahooSuffix: '.KS',
    tradableViaMoomoo: false,
  ),
  kosdaq(
    code: 'KOSDAQ',
    name: 'Korean Securities Dealers Automated Quotations',
    flag: '🇰🇷',
    currency: 'KRW',
    yahooSuffix: '.KQ',
    tradableViaMoomoo: false,
  ),
  // --- Global market expansion (Excel-backed universes on the backend) ---
  us(
    code: 'US',
    name: 'United States (NYSE/Nasdaq/AMEX)',
    flag: '🇺🇸',
    currency: 'USD',
    yahooSuffix: '',
    tradableViaMoomoo: false,
  ),
  japan(
    code: 'JAPAN',
    name: 'Japan Exchange Group (Tokyo)',
    flag: '🇯🇵',
    currency: 'JPY',
    yahooSuffix: '.T',
    tradableViaMoomoo: false,
  ),
  india(
    code: 'INDIA',
    name: 'National Stock Exchange of India',
    flag: '🇮🇳',
    currency: 'INR',
    yahooSuffix: '.NS',
    tradableViaMoomoo: false,
  ),
  vietnam(
    code: 'VIETNAM',
    name: 'Vietnam (HOSE/HNX/UPCOM)',
    flag: '🇻🇳',
    currency: 'VND',
    yahooSuffix: '.VN',
    tradableViaMoomoo: false,
  ),
  singapore(
    code: 'SINGAPORE',
    name: 'Singapore Exchange',
    flag: '🇸🇬',
    currency: 'SGD',
    yahooSuffix: '.SI',
    tradableViaMoomoo: false,
  );

  const Market({
    required this.code,
    required this.name,
    required this.flag,
    required this.currency,
    required this.yahooSuffix,
    required this.tradableViaMoomoo,
  });

  final String code;
  final String name;
  final String flag;
  final String currency;

  /// Yahoo Finance ticker suffix (e.g. HKEX -> '.HK').
  final String yahooSuffix;

  /// Whether manual Buy/Sell via Moomoo is offered for this market.
  final bool tradableViaMoomoo;
}
