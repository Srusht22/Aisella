import 'package:flutter/widgets.dart';

/// Kurdish Sorani (`ckb`, primary, RTL), Arabic (`ar`, RTL; Phase 9) and
/// English (`en`, LTR). Arabic strings are machine-drafted and pending
/// native-speaker review, like Sorani (DD-04).
abstract final class SupportedLocales {
  static const ckb = Locale('ckb');
  static const ar = Locale('ar');
  static const en = Locale('en');
  static const all = [ckb, ar, en];

  static Locale? byLanguageCode(String? code) =>
      all.where((l) => l.languageCode == code).firstOrNull;

  /// Initial suggestion on first launch: the device's language when it is
  /// Kurdish, Arabic or English, otherwise Sorani (the primary language).
  static Locale suggestFor(List<Locale> deviceLocales) {
    for (final l in deviceLocales) {
      if (l.languageCode == 'ckb' || l.languageCode == 'ku') return ckb;
      if (l.languageCode == 'ar') return ar;
      if (l.languageCode == 'en') return en;
    }
    return ckb;
  }

  static bool isRtl(Locale locale) =>
      const {'ckb', 'ar', 'fa'}.contains(locale.languageCode);
}
