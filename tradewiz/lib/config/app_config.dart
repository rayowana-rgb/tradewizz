/// App-wide configuration, overridable at build time via --dart-define.
///
/// Example:
///   flutter run --dart-define=TRADEWIZ_API_BASE_URL=https://staging.tradewiz.app/v1
class AppConfig {
  const AppConfig({
    required this.baseUrl,
    this.cdnBaseUrl = '',
    this.requestTimeout = const Duration(seconds: 25),
    this.mockFallback = true,
  });

  final String baseUrl;

  /// Public base URL of the Global Snapshot CDN (Phase 7), e.g. the R2 public
  /// bucket URL. Empty disables the CDN path (the app then uses the backend
  /// snapshot endpoints directly). The manifest lives at
  /// ``$cdnBaseUrl/snapshots/manifest.json``.
  final String cdnBaseUrl;

  bool get cdnEnabled => cdnBaseUrl.isNotEmpty;

  final Duration requestTimeout;

  /// When true, network failures fall back to mocked data so the app stays
  /// usable while the backend is offline or unreachable.
  final bool mockFallback;

  static const String _baseUrlFromEnv = String.fromEnvironment(
    'TRADEWIZ_API_BASE_URL',
    defaultValue: 'https://api.tradewiz.app/v1',
  );

  static const String _cdnBaseUrlFromEnv = String.fromEnvironment(
    'TRADEWIZ_CDN_BASE_URL',
    defaultValue: '',
  );

  static const bool _mockFallbackFromEnv = bool.fromEnvironment(
    'TRADEWIZ_MOCK_FALLBACK',
    defaultValue: true,
  );

  /// Config resolved from --dart-define values (with sensible defaults).
  ///
  /// `--dart-define=TRADEWIZ_MOCK_FALLBACK=false` disables the mock fallback so
  /// network errors surface instead of returning mocked data.
  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      baseUrl: _baseUrlFromEnv,
      cdnBaseUrl: _cdnBaseUrlFromEnv,
      mockFallback: _mockFallbackFromEnv,
    );
  }
}
