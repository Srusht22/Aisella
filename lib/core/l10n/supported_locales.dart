import 'package:flutter/widgets.dart';

/// Kurdish Sorani (`ckb`, primary, RTL) and English (`en`, LTR).
/// Arabic (`ar`) is architecture-ready but not shipped in P0 (Phase 1 §9.1).
abstract final class SupportedLocales {
  static const ckb = Locale('ckb');
  static const en = Locale('en');
  static const all = [ckb, en];

  static Locale? byLanguageCode(String? code) =>
      all.where((l) => l.languageCode == code).firstOrNull;

  /// Initial suggestion on first launch: Sorani when the device prefers a
  /// Kurdish or Arabic-script locale, otherwise English.
  static Locale suggestFor(List<Locale> deviceLocales) {
    for (final l in deviceLocales) {
      if (l.languageCode == 'ckb' || l.languageCode == 'ku') return ckb;
      if (l.languageCode == 'en') return en;
    }
    return ckb;
  }

  static bool isRtl(Locale locale) =>
      const {'ckb', 'ar', 'fa'}.contains(locale.languageCode);
}
