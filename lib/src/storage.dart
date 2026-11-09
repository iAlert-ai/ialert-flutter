import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Minimal async key/value storage the SDK persists into.
abstract class KeyValueStorage {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// In-memory storage (tests, or when nothing should persist).
class MemoryStorage implements KeyValueStorage {
  final Map<String, String> items = {};

  @override
  Future<String?> getString(String key) async => items[key];

  @override
  Future<void> setString(String key, String value) async => items[key] = value;

  @override
  Future<void> remove(String key) async => items.remove(key);
}

/// Default storage backed by `shared_preferences`.
class SharedPreferencesStorage implements KeyValueStorage {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  @override
  Future<String?> getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) => _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// Namespaced JSON helpers over a [KeyValueStorage]; never throws.
class Store {
  Store(this._storage, String namespace) : _prefix = 'ialert:$namespace:';

  final KeyValueStorage _storage;
  final String _prefix;

  Future<Object?> get(String key) async {
    try {
      final raw = await _storage.getString(_prefix + key);
      return raw == null ? null : jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> set(String key, Object? value) async {
    try {
      await _storage.setString(_prefix + key, jsonEncode(value));
    } catch (_) {
      // Storage failed: the SDK keeps working for this run.
    }
  }

  Future<void> remove(String key) async {
    try {
      await _storage.remove(_prefix + key);
    } catch (_) {}
  }
}
