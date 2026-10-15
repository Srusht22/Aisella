import 'dart:math';

final _random = Random.secure();

/// A random (version 4) UUID used as an idempotency key (ADR-005).
///
/// One key belongs to one user intent: retries of the same request reuse it;
/// a changed request gets a new key, otherwise the server would answer
/// `IDEMPOTENCY_KEY_REUSED`.
String newIdempotencyKey() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Keeps one idempotency key per user intent across retries: the key changes
/// only when the request payload changes.
class IntentKey {
  String? _key;
  Object? _payload;

  /// Returns the key to send for [payload] (compared with `==`; pass a
  /// value-equal representation such as a canonical string).
  String forPayload(Object payload) {
    if (_key == null || _payload != payload) {
      _key = newIdempotencyKey();
      _payload = payload;
    }
    return _key!;
  }

  /// Call after the intent has succeeded, so the next intent gets a new key.
  void reset() {
    _key = null;
    _payload = null;
  }
}
