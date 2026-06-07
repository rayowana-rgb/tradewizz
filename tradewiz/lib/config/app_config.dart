/// App-wide configuration, overridable at build time via --dart-define.
///
/// Example:
///   flutter run --dart-define=TRADEWIZ_API_BASE_URL=https://staging.tradewiz.app/v1
class AppConfig {
  const AppConfig({
    required this.baseUrl,
    this.requestTimeout = const Duration(seconds: 10),
    this.mockFallback = true,
  });

  final String baseUrl;
  final Duration requestTimeout;

  /// When true, network failures fall back to mocked data so the app stays
  /// usable while the backend is offline or unreachable.
  final bool mockFallback;

  static const String _baseUrlFromEnv = String.fromEnvironment(
    'TRADEWIZ_API_BASE_URL',
    defaultValue: 'https://api.tradewiz.app/v1',
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
      mockFallback: _mockFallbackFromEnv,
    );
  }
}
