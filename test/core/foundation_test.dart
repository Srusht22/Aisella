import 'dart:convert';
import 'dart:io';

import 'package:aisellia/core/config/app_config.dart';
import 'package:aisellia/core/formatting/bidi.dart';
import 'package:aisellia/core/formatting/dates.dart';
import 'package:aisellia/core/formatting/digits.dart';
import 'package:aisellia/core/formatting/money.dart';
import 'package:aisellia/core/formatting/phone.dart';
import 'package:aisellia/core/settings/app_settings.dart';
import 'package:aisellia/core/settings/key_value_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

String _strip(String s) => s.replaceAll(RegExp('[\u2066-\u2069]'), '');

void main() {
  group('AppConfig', () {
    const url = 'https://project.supabase.co';
    const key = 'sb_publishable_test';
    AppConfig make({
      String? env,
      String? sample,
      String? u = url,
      String? k = key,
    }) => AppConfig.fromValues(
      envName: env,
      sampleData: sample,
      supabaseUrl: u,
      supabasePublishableKey: k,
    );
    // Builds a JWT-shaped string with the given role claim. Not a real key.
    String jwtWithRole(String role) =>
        'header.${base64Url.encode(utf8.encode('{"role":"$role"}')).replaceAll('=', '')}.sig';

    test('defaults to dev with sample data', () {
      final c = make();
      expect(c.environment, AppEnvironment.dev);
      expect(c.sampleData, isTrue);
      expect(c.supabaseUrl, Uri.parse(url));
    });
    test('staging and prod default to no sample data', () {
      expect(make(env: 'staging').sampleData, isFalse);
      expect(make(env: 'prod').sampleData, isFalse);
    });
    test('rejects sample data in prod', () {
      expect(
        () => make(env: 'prod', sample: 'true'),
        throwsA(isA<AppConfigException>()),
      );
    });
    test('rejects unknown values', () {
      expect(() => make(env: 'qa'), throwsA(isA<AppConfigException>()));
      expect(() => make(sample: 'yes'), throwsA(isA<AppConfigException>()));
    });
    test('requires the backend URL and publishable key', () {
      expect(() => make(u: ''), throwsA(isA<AppConfigException>()));
      expect(() => make(k: ''), throwsA(isA<AppConfigException>()));
      expect(() => make(u: 'not a url'), throwsA(isA<AppConfigException>()));
    });
    test('plain http is allowed only for a dev build', () {
      expect(make(u: 'http://127.0.0.1:54321').supabaseUrl!.port, 54321);
      expect(
        () => make(env: 'staging', u: 'http://staging.example.test'),
        throwsA(isA<AppConfigException>()),
      );
    });
    test('refuses privileged keys in the app', () {
      expect(
        () => make(k: 'sb_secret_abc'),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => make(k: jwtWithRole('service_role')),
        throwsA(isA<AppConfigException>()),
      );
      expect(make(k: jwtWithRole('anon')).supabasePublishableKey, isNotEmpty);
    });
  });

  group('Digits', () {
    test('normalises Eastern Arabic and Persian digits', () {
      expect(Digits.normalize('٣٥٠٠٠'), '35000');
      expect(Digits.normalize('۱۲۳'), '123');
      expect(Digits.normalize('a١b'), 'a1b');
    });
    test('groups thousands', () {
      expect(Digits.group(0), '0');
      expect(Digits.group(999), '999');
      expect(Digits.group(35000), '35,000');
      expect(Digits.group(1250000), '1,250,000');
      expect(Digits.group(-4500), '-4,500');
    });
    test('displays Eastern digits with Arabic thousands separator', () {
      expect(Digits.display('35,000', DigitStyle.eastern), '٣٥٬٠٠٠');
      expect(Digits.display('35,000', DigitStyle.western), '35,000');
    });
  });

  group('Money', () {
    test('IQD unit per locale, number isolated LTR', () {
      final en = Money.format(
        35000,
        Currency.iqd,
        locale: const Locale('en'),
        digits: DigitStyle.western,
      );
      final ckb = Money.format(
        35000,
        Currency.iqd,
        locale: const Locale('ckb'),
        digits: DigitStyle.western,
      );
      expect(_strip(en), '35,000 IQD');
      expect(_strip(ckb), '35,000 د.ع');
      expect(
        en.startsWith('\u2066'),
        isTrue,
        reason: 'amount must be an LTR isolate',
      );
    });
    test('USD and Eastern digits', () {
      expect(
        _strip(
          Money.format(
            25,
            Currency.usd,
            locale: const Locale('en'),
            digits: DigitStyle.western,
          ),
        ),
        r'$25',
      );
      expect(
        _strip(
          Money.format(
            1250000,
            Currency.iqd,
            locale: const Locale('ckb'),
            digits: DigitStyle.eastern,
          ),
        ),
        '١٬٢٥٠٬٠٠٠ د.ع',
      );
    });
  });

  group('PhoneNumbers', () {
    test('normalises Iraqi mobile formats', () {
      for (final input in [
        '0750 123 4567',
        '+964 750 123 4567',
        '009647501234567',
        '٠٧٥٠١٢٣٤٥٦٧',
        '964-750-123-4567',
      ]) {
        expect(
          PhoneNumbers.normalizeIraqMobile(input),
          '+9647501234567',
          reason: input,
        );
      }
    });
    test('rejects invalid numbers', () {
      expect(PhoneNumbers.normalizeIraqMobile('12345'), isNull);
      expect(PhoneNumbers.normalizeIraqMobile('+96421234567'), isNull);
    });
    test('display is grouped, Western digits, LTR isolated', () {
      final d = PhoneNumbers.display('+9647501234567');
      expect(_strip(d), '+964 750 123 4567');
      expect(d.startsWith('\u2066'), isTrue);
    });
  });

  group('Bidi', () {
    test('detects direction from the first strong character', () {
      expect(Bidi.detect('Beige Abaya'), TextDirection.ltr);
      expect(Bidi.detect('عەبای ڕەش'), TextDirection.rtl);
      expect(Bidi.detect('123 عەبا'), TextDirection.rtl);
      expect(Bidi.detect('123'), isNull);
    });
  });

  group('Dates', () {
    test('day month year in English and Sorani', () {
      final d = DateTime(2026, 10, 29);
      expect(
        Dates.dayMonthYear(
          d,
          locale: const Locale('en'),
          digits: DigitStyle.western,
        ),
        '29 October 2026',
      );
      expect(
        Dates.dayMonthYear(
          d,
          locale: const Locale('ckb'),
          digits: DigitStyle.western,
        ),
        '29ی تشرینی یەکەمی 2026',
      );
    });

    test('English and Sorani weekday/day/month', () {
      final d = DateTime(2026, 10, 15); // Thursday
      expect(
        Dates.weekdayDayMonth(
          d,
          locale: const Locale('en'),
          digits: DigitStyle.western,
        ),
        'Thursday, 15 October',
      );
      expect(
        Dates.weekdayDayMonth(
          d,
          locale: const Locale('ckb'),
          digits: DigitStyle.eastern,
        ),
        'پێنجشەممە، ١٥ی تشرینی یەکەم',
      );
    });
  });

  group('SettingsController', () {
    test(
      'persists and reloads choices; unknown stored values fall back',
      () async {
        final store = InMemoryStore({'settings.theme': 'neon'});
        final c = ProviderContainer(
          overrides: [keyValueStoreProvider.overrideWithValue(store)],
        );
        addTearDown(c.dispose);
        expect(c.read(settingsProvider).theme, ThemePreference.system);
        expect(c.read(settingsProvider).languageChosen, isFalse);
        await c.read(settingsProvider.notifier).setLocale(const Locale('ckb'));
        await c.read(settingsProvider.notifier).setDigits(DigitStyle.eastern);
        await c
            .read(settingsProvider.notifier)
            .setMotion(MotionPreference.reduce);

        final reloaded = ProviderContainer(
          overrides: [keyValueStoreProvider.overrideWithValue(store)],
        );
        addTearDown(reloaded.dispose);
        final s = reloaded.read(settingsProvider);
        expect(s.locale, const Locale('ckb'));
        expect(s.digits, DigitStyle.eastern);
        expect(s.motion, MotionPreference.reduce);
      },
    );
    test('ignores unsupported locales', () async {
      final c = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(InMemoryStore())],
      );
      addTearDown(c.dispose);
      await c.read(settingsProvider.notifier).setLocale(const Locale('fr'));
      expect(c.read(settingsProvider).locale, isNull);
    });
  });

  group('Localization files', () {
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;
    test('Sorani has every English key and no extras', () {
      final en = arb('en').keys.where((k) => !k.startsWith('@')).toSet();
      final ckb = arb('ckb').keys.where((k) => !k.startsWith('@')).toSet();
      expect(ckb.difference(en), isEmpty);
      expect(en.difference(ckb), isEmpty);
    });
    test('Sorani strings contain no literal bidi control characters', () {
      final values = arb('ckb').values.whereType<String>();
      for (final v in values) {
        expect(
          RegExp('[\u202a-\u202e\u2066-\u2069]').hasMatch(v),
          isFalse,
          reason: v,
        );
      }
    });
  });
}
