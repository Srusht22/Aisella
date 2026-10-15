import 'package:flutter/widgets.dart';

/// Unicode bidi isolates (Phase 2 §07 §2.3). Isolated runs keep phone numbers,
/// order numbers, SKUs and amounts reading left-to-right inside RTL text
/// without disturbing neighbouring punctuation.
abstract final class Bidi {
  static const _lri = '\u2066'; // LEFT-TO-RIGHT ISOLATE
  static const _fsi = '\u2068'; // FIRST STRONG ISOLATE
  static const _pdi = '\u2069'; // POP DIRECTIONAL ISOLATE

  /// Wraps [text] so it always renders LTR as one unit.
  static String ltr(String text) => '$_lri$text$_pdi';

  /// Wraps user content so its direction comes from its own first strong
  /// character (e.g. a Latin product name inside a Sorani sentence).
  static String auto(String text) => '$_fsi$text$_pdi';

  static final _rtlChar = RegExp('[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]');
  static final _ltrChar = RegExp('[A-Za-z\u00C0-\u024F]');

  /// Direction of the first strong character; used for user-entered text
  /// (product names, customer messages) whose script is unknown.
  static TextDirection? detect(String text) {
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (_rtlChar.hasMatch(ch)) return TextDirection.rtl;
      if (_ltrChar.hasMatch(ch)) return TextDirection.ltr;
    }
    return null;
  }
}
