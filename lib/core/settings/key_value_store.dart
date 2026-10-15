import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local storage for UI preferences only (language, digits, theme,
/// motion) and the install marker. Never used for tokens, business data or
/// personal data: the session lives in the keystore (ADR-013).
abstract interface class KeyValueStore {
  String? read(String key);
  Future<void> write(String key, String value);
}

/// Production implementation backed by `shared_preferences`.
class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore(this._prefs);

  final SharedPreferencesWithCache _prefs;

  static const allowedKeys = {
    'settings.locale',
    'settings.digits',
    'settings.theme',
    'settings.motion',
    installMarkerKey,
  };

  /// Set on the first launch of an installation (see bootstrap).
  static const installMarkerKey = 'install.initialized';

  static Future<SharedPreferencesStore> open() async => SharedPreferencesStore(
    await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(
        allowList: allowedKeys,
      ),
    ),
  );

  @override
  String? read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String value) => _prefs.setString(key, value);
}

/// Used in tests, and as a fallback if platform storage cannot be opened
/// (preferences then last for the session only).
class InMemoryStore implements KeyValueStore {
  InMemoryStore([Map<String, String>? initial]) : _values = {...?initial};

  final Map<String, String> _values;

  @override
  String? read(String key) => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

final keyValueStoreProvider = Provider<KeyValueStore>(
  (ref) => throw StateError('keyValueStoreProvider must be overridden.'),
);
