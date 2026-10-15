import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Session persistence in the platform keystore (ADR-013): the refresh token
/// lives in the iOS Keychain / Android Keystore-backed storage, never in
/// shared preferences. Cleared on sign-out by the auth client.
class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? defaultSecureStorage;

  static const sessionKey = 'aisellia.auth.session';

  final FlutterSecureStorage _storage;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() => _storage.containsKey(key: sessionKey);

  @override
  Future<String?> accessToken() => _storage.read(key: sessionKey);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: sessionKey, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: sessionKey);
}

/// PKCE code-verifier storage for email links (verification and password
/// reset), also kept in the keystore.
class SecurePkceStorage extends GotrueAsyncStorage {
  SecurePkceStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? defaultSecureStorage;

  static const prefix = 'aisellia.auth.pkce.';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> getItem({required String key}) =>
      _storage.read(key: '$prefix$key');

  @override
  Future<void> setItem({required String key, required String value}) =>
      _storage.write(key: '$prefix$key', value: value);

  @override
  Future<void> removeItem({required String key}) =>
      _storage.delete(key: '$prefix$key');
}

/// Keychain items are not accessible while the device is locked and are not
/// migrated to other devices by backups.
const defaultSecureStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);

/// The iOS Keychain survives app deletion. On the first launch after an
/// install, remove anything a previous installation left behind so a
/// reinstalled app never restores an old seller's session.
Future<void> clearSessionLeftFromPreviousInstall(
  FlutterSecureStorage storage,
) async {
  final all = await storage.readAll();
  for (final key in all.keys) {
    if (key == SecureSessionStorage.sessionKey ||
        key.startsWith(SecurePkceStorage.prefix)) {
      await storage.delete(key: key);
    }
  }
}
