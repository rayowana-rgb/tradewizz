import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';

/// Persistence seam for the auth session (token + user), testable without disk.
abstract class AuthPersistence {
  Future<({String token, UserProfile user})?> load();
  Future<void> save(String token, UserProfile user);
  Future<void> clear();
}

/// shared_preferences-backed session persistence.
class SharedPrefsAuthPersistence implements AuthPersistence {
  static const _tokenKey = 'tradewizz.auth.token';
  static const _userKey = 'tradewizz.auth.user';

  @override
  Future<({String token, UserProfile user})?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    final userJson = prefs.getString(_userKey);
    if (token == null || token.isEmpty || userJson == null) return null;
    try {
      final user = UserProfile.fromJson(
          jsonDecode(userJson) as Map<String, dynamic>);
      return (token: token, user: user);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String token, UserProfile user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
  }
}

/// App-wide auth session. A [ChangeNotifier] so the UI reacts to login/logout.
class AuthStore extends ChangeNotifier {
  AuthStore({this.persistence});

  final AuthPersistence? persistence;

  String? _token;
  UserProfile? _user;
  bool _loaded = false;

  bool get isLoggedIn => _token != null && _user != null;
  bool get isLoaded => _loaded;
  String? get token => _token;
  UserProfile? get user => _user;

  /// Restore a persisted session once on startup.
  Future<void> load() async {
    if (_loaded) return;
    final p = persistence;
    if (p != null) {
      final session = await p.load();
      if (session != null) {
        _token = session.token;
        _user = session.user;
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setSession(String token, UserProfile user) async {
    _token = token;
    _user = user;
    notifyListeners();
    await persistence?.save(token, user);
  }

  /// Update just the profile (e.g. refreshed from /me) keeping the token.
  void setUser(UserProfile user) {
    _user = user;
    notifyListeners();
    if (_token != null) {
      persistence?.save(_token!, user);
    }
  }

  Future<void> clear() async {
    _token = null;
    _user = null;
    notifyListeners();
    await persistence?.clear();
  }
}
