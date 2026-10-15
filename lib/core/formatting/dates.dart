import 'package:flutter/widgets.dart';

import '../settings/app_settings.dart';
import 'digits.dart';

/// Localised dates (Gregorian calendar).
///
/// The `intl` package has no `ckb` date data (verified in Phase 4), so
/// names are provided here. Sorani month names follow the KRI Gregorian
/// usage (Syriac-derived); **pending native review (DD-09)**.
abstract final class Dates {
  static const _enWeekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const _enMonths = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  static const _ckbWeekdays = [
    'دووشەممە',
    'سێشەممە',
    'چوارشەممە',
    'پێنجشەممە',
    'هەینی',
    'شەممە',
    'یەکشەممە',
  ];
  static const _ckbMonths = [
    'کانوونی دووەم',
    'شوبات',
    'ئازار',
    'نیسان',
    'ئایار',
    'حوزەیران',
    'تەممووز',
    'ئاب',
    'ئەیلوول',
    'تشرینی یەکەم',
    'تشرینی دووەم',
    'کانوونی یەکەم',
  ];

  /// "Thursday, 15 October" / "پێنجشەممە، 15ی تشرینی یەکەم".
  static String weekdayDayMonth(
    DateTime date, {
    required Locale locale,
    required DigitStyle digits,
  }) {
    final day = Digits.display('${date.day}', digits);
    if (locale.languageCode == 'ckb') {
      return '${_ckbWeekdays[date.weekday - 1]}، $dayی ${_ckbMonths[date.month - 1]}';
    }
    return '${_enWeekdays[date.weekday - 1]}, $day ${_enMonths[date.month - 1]}';
  }
}
