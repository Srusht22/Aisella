import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/supported_locales.dart';
import 'key_value_store.dart';

/// Display style for amounts, counts and dates (Phase 2 §07 §3, D-10).
/// Phone numbers, SKUs and order numbers always use Western digits (DD-07).
enum DigitStyle { western, eastern }

enum ThemePreference { system, light, dark }

enum MotionPreference { system, reduce }

/// Colour theme: the brand colour and the tint of the neutrals. `ledger`
/// is the original Aisellia indigo. Each has a light and a dark version.
enum AppAccent {
  ledger,
  gold,
  emerald,
  sapphire,
  ruby,
  amethyst,
  rose,
  teal,
  copper,
  onyx,
}

@immutable
class AppSettings {
  const AppSettings({
    this.locale,
    this.digits = DigitStyle.western,
    this.theme = ThemePreference.system,
    this.motion = MotionPreference.system,
    this.accent = AppAccent.ledger,
  });

  /// `null` until the user picks a language on first launch (AU-01).
  final Locale? locale;
  final DigitStyle digits;
  final ThemePreference theme;
  final MotionPreference motion;
  final AppAccent accent;

  bool get languageChosen => locale != null;

  AppSettings copyWith({
    Locale? locale,
    DigitStyle? digits,
    ThemePreference? theme,
    MotionPreference? motion,
    AppAccent? accent,
  }) => AppSettings(
    locale: locale ?? this.locale,
    digits: digits ?? this.digits,
    theme: theme ?? this.theme,
    motion: motion ?? this.motion,
    accent: accent ?? this.accent,
  );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.locale == locale &&
      other.digits == digits &&
      other.theme == theme &&
      other.motion == motion &&
      other.accent == accent;

  @override
  int get hashCode => Object.hash(locale, digits, theme, motion, accent);
}

/// Reads and persists [AppSettings]. Unknown stored values fall back to
/// defaults rather than failing.
class SettingsController extends Notifier<AppSettings> {
  static const _kLocale = 'settings.locale';
  static const _kDigits = 'settings.digits';
  static const _kTheme = 'settings.theme';
  static const _kMotion = 'settings.motion';
  static const _kAccent = 'settings.accent';

  KeyValueStore get _store => ref.read(keyValueStoreProvider);

  @override
  AppSettings build() {
    final store = ref.watch(keyValueStoreProvider);
    T parse<T extends Enum>(List<T> values, String key, T fallback) {
      final raw = store.read(key);
      return values.where((v) => v.name == raw).firstOrNull ?? fallback;
    }

    final rawLocale = store.read(_kLocale);
    return AppSettings(
      locale: SupportedLocales.byLanguageCode(rawLocale),
      digits: parse(DigitStyle.values, _kDigits, DigitStyle.western),
      theme: parse(ThemePreference.values, _kTheme, ThemePreference.system),
      motion: parse(MotionPreference.values, _kMotion, MotionPreference.system),
      accent: parse(AppAccent.values, _kAccent, AppAccent.ledger),
    );
  }

  Future<void> setLocale(Locale locale) async {
    final supported = SupportedLocales.byLanguageCode(locale.languageCode);
    if (supported == null) return;
    state = state.copyWith(locale: supported);
    await _store.write(_kLocale, supported.languageCode);
  }

  Future<void> setDigits(DigitStyle digits) async {
    state = state.copyWith(digits: digits);
    await _store.write(_kDigits, digits.name);
  }

  Future<void> setTheme(ThemePreference theme) async {
    state = state.copyWith(theme: theme);
    await _store.write(_kTheme, theme.name);
  }

  Future<void> setAccent(AppAccent accent) async {
    state = state.copyWith(accent: accent);
    await _store.write(_kAccent, accent.name);
  }

  Future<void> setMotion(MotionPreference motion) async {
    state = state.copyWith(motion: motion);
    await _store.write(_kMotion, motion.name);
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);
