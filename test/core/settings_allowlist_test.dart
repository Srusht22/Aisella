import 'package:aisellia/core/settings/app_settings.dart';
import 'package:aisellia/core/settings/key_value_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fails like the real store does for a key outside its allowlist (on the
/// web this blanked the whole app).
class _StrictStore extends InMemoryStore {
  void _check(String key) {
    if (!SharedPreferencesStore.allowedKeys.contains(key)) {
      throw ArgumentError('$key is not in the allowlist');
    }
  }

  @override
  String? read(String key) {
    _check(key);
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    _check(key);
    return super.write(key, value);
  }
}

void main() {
  test('every setting is readable and writable through the real store', () {
    final container = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(_StrictStore())],
    );
    addTearDown(container.dispose);
    final ctl = container.read(settingsProvider.notifier);
    expect(container.read(settingsProvider).accent, AppAccent.ledger);
    expect(() async {
      await ctl.setLocale(const Locale('ckb'));
      await ctl.setDigits(DigitStyle.eastern);
      await ctl.setTheme(ThemePreference.dark);
      await ctl.setMotion(MotionPreference.reduce);
      await ctl.setAccent(AppAccent.gold);
    }(), completes);
  });
}
