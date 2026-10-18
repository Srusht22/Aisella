import 'package:flutter/widgets.dart';

import '../settings/app_settings.dart';
import 'bidi.dart';
import 'digits.dart';

/// Store currency: one per store, integer amounts only (Phase 1 BR-12, D-08).
enum Currency { iqd, usd }

/// Formats integer money amounts (Phase 2 §07 §3; unit labels pending
/// native review, DD-08).
abstract final class Money {
  /// IQD: "35,000 IQD" (en) / "35,000 د.ع" (ckb). USD: "$25" in both.
  /// The numeric part is an LTR isolate so it never reorders inside RTL text.
  static String format(
    int amount,
    Currency currency, {
    required Locale locale,
    required DigitStyle digits,
  }) {
    final number = Digits.display(Digits.group(amount), digits);
    return switch (currency) {
      Currency.iqd =>
        '${Bidi.ltr(number)} ${const {'ckb', 'ar'}.contains(locale.languageCode) ? 'د.ع' : 'IQD'}',
      Currency.usd => Bidi.ltr('\$$number'),
    };
  }

  /// Bare grouped number (for compact columns where the currency is stated
  /// once, e.g. order line prices).
  static String amount(int amount, {required DigitStyle digits}) =>
      Bidi.ltr(Digits.display(Digits.group(amount), digits));
}
