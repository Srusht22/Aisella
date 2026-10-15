import 'bidi.dart';
import 'digits.dart';

/// Iraqi phone-number handling (Phase 1 §8.7, Phase 2 §07 §3).
/// Phone numbers always display with Western digits, LTR-isolated (DD-07).
abstract final class PhoneNumbers {
  static final _iraqMobile = RegExp(r'^\+9647\d{9}$');

  /// Normalises `07xx…`, `+9647…`, `009647…`, spaces, dashes and Eastern
  /// digits to E.164 (`+9647XXXXXXXXX`). Returns `null` if it is not a valid
  /// Iraqi mobile number.
  static String? normalizeIraqMobile(String input) {
    var s = Digits.normalize(input).replaceAll(RegExp(r'[\s\-().]'), '');
    if (s.startsWith('00')) s = '+${s.substring(2)}';
    if (s.startsWith('0')) s = '+964${s.substring(1)}';
    if (s.startsWith('964')) s = '+$s';
    return _iraqMobile.hasMatch(s) ? s : null;
  }

  /// `+9647501234567` → `+964 750 123 4567`, isolated for RTL contexts.
  static String display(String e164) {
    if (!_iraqMobile.hasMatch(e164)) return Bidi.ltr(e164);
    final local = e164.substring(4);
    return Bidi.ltr(
      '+964 ${local.substring(0, 3)} ${local.substring(3, 6)} ${local.substring(6)}',
    );
  }
}
