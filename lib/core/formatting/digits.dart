import '../settings/app_settings.dart';

/// Digit normalisation and display (Phase 2 §07 §3).
abstract final class Digits {
  static const _arabicIndicZero = 0x0660; // ٠
  static const _persianZero = 0x06F0; // ۰
  static const _arabicThousands = '٬'; // ٬

  /// Converts Eastern Arabic and Persian digits to ASCII so input typed in
  /// any style is accepted (L10N-06).
  static String normalize(String input) {
    final out = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= _arabicIndicZero && rune <= _arabicIndicZero + 9) {
        out.writeCharCode(0x30 + rune - _arabicIndicZero);
      } else if (rune >= _persianZero && rune <= _persianZero + 9) {
        out.writeCharCode(0x30 + rune - _persianZero);
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  /// Renders ASCII digits in the chosen display style. With Eastern digits the
  /// thousands separator becomes U+066C.
  static String display(String ascii, DigitStyle style) {
    if (style == DigitStyle.western) return ascii;
    final out = StringBuffer();
    for (final rune in ascii.runes) {
      if (rune >= 0x30 && rune <= 0x39) {
        out.writeCharCode(_arabicIndicZero + rune - 0x30);
      } else if (rune == 0x2C) {
        out.write(_arabicThousands);
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  /// Integer with thousands grouping, e.g. 1250000 → "1,250,000".
  static String group(int value) {
    final negative = value < 0;
    final digits = value.abs().toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return negative ? '-$out' : out.toString();
  }
}
