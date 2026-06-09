import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// The CDN manifest (Phase C) downloaded from
/// ``$cdnBaseUrl/snapshots/manifest.json``.
///
/// Drives change detection (Phase E) and per-object delta downloads (Phase G):
/// only objects whose content hash changed are re-fetched.
class CdnManifest {
  CdnManifest({
    required this.version,
    required this.generatedAt,
    required this.hashes,
    required this.sizes,
    required this.markets,
  });

  final String version;
  final String generatedAt;

  /// relative object key -> sha256 content hash.
  final Map<String, String> hashes;

  /// relative object key -> byte size.
  final Map<String, int> sizes;

  /// market code -> dashboard hash (convenience mirror of [hashes]).
  final Map<String, String> markets;

  factory CdnManifest.fromJson(Map<String, dynamic> j) {
    Map<String, String> strMap(Object? v) => (v is Map)
        ? v.map((k, val) => MapEntry(k.toString(), val.toString()))
        : <String, String>{};
    Map<String, int> intMap(Object? v) => (v is Map)
        ? v.map((k, val) =>
            MapEntry(k.toString(), (val is num ? val.toInt() : 0)))
        : <String, int>{};
    return CdnManifest(
      version: (j['version'] ?? '').toString(),
      generatedAt: (j['generated_at'] ?? '').toString(),
      hashes: strMap(j['hashes']),
      sizes: intMap(j['sizes']),
      markets: strMap(j['markets']),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'generated_at': generatedAt,
        'hashes': hashes,
        'sizes': sizes,
        'markets': markets,
      };

  /// Object keys whose hash differs from [previous] (or all keys if none).
  /// This is the delta-download set (Phase G).
  List<String> changedKeys(CdnManifest? previous) {
    if (previous == null) return hashes.keys.toList()..sort();
    final changed = <String>[];
    hashes.forEach((key, h) {
      if (previous.hashes[key] != h) changed.add(key);
    });
    changed.sort();
    return changed;
  }

  bool sameVersion(CdnManifest? other) =>
      other != null && other.version == version && _hashesEqual(other);

  bool _hashesEqual(CdnManifest other) {
    if (other.hashes.length != hashes.length) return false;
    for (final e in hashes.entries) {
      if (other.hashes[e.key] != e.value) return false;
    }
    return true;
  }
}

/// Downloads CDN objects over plain HTTP (no auth, no mock fallback).
///
/// On any network/parse error it returns ``null`` so callers fall back to Hive
/// (Phase H offline-first). It never throws for a missing/unreachable CDN.
class ManifestService {
  ManifestService({AppConfig? config, http.Client? httpClient})
      : _config = config ?? AppConfig.fromEnvironment(),
        _http = httpClient ?? http.Client();

  final AppConfig _config;
  final http.Client _http;

  bool get enabled => _config.cdnEnabled;

  String get _root => '${_config.cdnBaseUrl.replaceAll(RegExp(r"/+$"), "")}'
      '/snapshots';

  Uri _uri(String key) => Uri.parse('$_root/$key');

  /// Fetch and parse ``manifest.json``. Returns null when the CDN is disabled
  /// or unreachable (offline-first: caller uses Hive).
  Future<CdnManifest?> fetchManifest() async {
    if (!enabled) return null;
    final raw = await _getJson('manifest.json');
    if (raw == null) return null;
    try {
      return CdnManifest.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  /// Download a single CDN object by relative key (e.g.
  /// ``markets/US/dashboard.json``). Returns the decoded JSON + byte size, or
  /// null on failure. Validation (Phase K) is done by the caller.
  Future<CdnObject?> fetchObject(String key) async {
    if (!enabled) return null;
    try {
      final resp = await _http
          .get(_uri(key), headers: const {'Accept': 'application/json'})
          .timeout(_config.requestTimeout);
      if (resp.statusCode != 200) return null;
      final bytes = resp.bodyBytes.length;
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map) return null;
      return CdnObject(
        key: key,
        json: Map<String, dynamic>.from(decoded),
        bytes: bytes,
      );
    } catch (_) {
      return null; // offline-first: never throw, caller uses Hive.
    }
  }

  Future<Map<String, dynamic>?> _getJson(String key) async {
    try {
      final resp = await _http
          .get(_uri(key), headers: const {'Accept': 'application/json'})
          .timeout(_config.requestTimeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}

class CdnObject {
  CdnObject({required this.key, required this.json, required this.bytes});
  final String key;
  final Map<String, dynamic> json;
  final int bytes;
}
