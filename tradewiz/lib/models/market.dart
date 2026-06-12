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
    moomooSuffix: 'ID',
  ),
  hkex(
    code: 'HKEX',
    name: 'Hong Kong Stock Exchange',
    flag: '🇭🇰',
    currency: 'HKD',
    yahooSuffix: '.HK',
    tradableViaMoomoo: true,
    moomooSuffix: 'HK',
  ),
  kospi(
    code: 'KOSPI',
    name: 'Korea Composite Stock Price Index',
    flag: '🇰🇷',
    currency: 'KRW',
    yahooSuffix: '.KS',
    tradableViaMoomoo: false,
    moomooSuffix: 'KR',
  ),
  kosdaq(
    code: 'KOSDAQ',
    name: 'Korean Securities Dealers Automated Quotations',
    flag: '🇰🇷',
    currency: 'KRW',
    yahooSuffix: '.KQ',
    tradableViaMoomoo: false,
    moomooSuffix: 'KR',
  ),
  // --- Global market expansion (Excel-backed universes on the backend) ---
  us(
    code: 'US',
    name: 'United States (NYSE/Nasdaq/AMEX)',
    flag: '🇺🇸',
    currency: 'USD',
    yahooSuffix: '',
    tradableViaMoomoo: false,
    moomooSuffix: 'US',
  ),
  japan(
    code: 'JAPAN',
    name: 'Japan Exchange Group (Tokyo)',
    flag: '🇯🇵',
    currency: 'JPY',
    yahooSuffix: '.T',
    tradableViaMoomoo: false,
    moomooSuffix: 'JP',
  ),
  india(
    code: 'INDIA',
    name: 'National Stock Exchange of India',
    flag: '🇮🇳',
    currency: 'INR',
    yahooSuffix: '.NS',
    tradableViaMoomoo: false,
    // Moomoo does not list Indian equities; no clean symbol page.
    moomooSuffix: null,
  ),
  vietnam(
    code: 'VIETNAM',
    name: 'Vietnam (HOSE/HNX/UPCOM)',
    flag: '🇻🇳',
    currency: 'VND',
    yahooSuffix: '.VN',
    tradableViaMoomoo: false,
    // Moomoo does not list Vietnamese equities; no clean symbol page.
    moomooSuffix: null,
  ),
  singapore(
    code: 'SINGAPORE',
    name: 'Singapore Exchange',
    flag: '🇸🇬',
    currency: 'SGD',
    yahooSuffix: '.SI',
    tradableViaMoomoo: false,
    moomooSuffix: 'SG',
  );

  const Market({
    required this.code,
    required this.name,
    required this.flag,
    required this.currency,
    required this.yahooSuffix,
    required this.tradableViaMoomoo,
    required this.moomooSuffix,
  });

  final String code;
  final String name;
  final String flag;
  final String currency;

  /// Yahoo Finance ticker suffix (e.g. HKEX -> '.HK').
  final String yahooSuffix;

  /// Whether manual Buy/Sell via Moomoo is offered for this market.
  final bool tradableViaMoomoo;

  /// Market suffix used by Moomoo's web/app symbol pages
  /// (`moomoo.com/stock/<SYMBOL>-<SUFFIX>`). Null when Moomoo does not list
  /// this market, so the broker hand-off just opens the app instead of
  /// building a link that would 404.
  final String? moomooSuffix;

  /// Resolve a [Market] from its wire code (e.g. 'US'); defaults to IDX.
  static Market fromCode(String? code) {
    final c = (code ?? '').toUpperCase();
    return Market.values.firstWhere(
      (m) => m.code == c,
      orElse: () => Market.idx,
    );
  }
}
