import 'package:flutter/widgets.dart';

import '../settings/app_settings.dart';
import 'bidi.dart';
import 'digits.dart';

/// Localised dates (Gregorian calendar).
///
/// The `intl` package has no `ckb` date data (verified in Phase 4), so
/// names are provided here. Sorani month names follow the KRI Gregorian
/// usage (Syriac-derived); **pending native review (DD-09)**. Arabic uses
/// the same Syriac month names, as written in Iraq.
abstract final class Dates {
  static const _arWeekdays = [
    'الاثنين',
    'الثلاثاء',
    'الأربعاء',
    'الخميس',
    'الجمعة',
    'السبت',
    'الأحد',
  ];
  static const _arMonths = [
    'كانون الثاني',
    'شباط',
    'آذار',
    'نيسان',
    'أيار',
    'حزيران',
    'تموز',
    'آب',
    'أيلول',
    'تشرين الأول',
    'تشرين الثاني',
    'كانون الأول',
  ];
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
    if (locale.languageCode == 'ar') {
      return '${_arWeekdays[date.weekday - 1]}، $day ${_arMonths[date.month - 1]}';
    }
    return '${_enWeekdays[date.weekday - 1]}, $day ${_enMonths[date.month - 1]}';
  }

  /// "29 October 2026" / "29ی تشرینی یەکەمی 2026".
  static String dayMonthYear(
    DateTime date, {
    required Locale locale,
    required DigitStyle digits,
  }) {
    final day = Digits.display('${date.day}', digits);
    final year = Digits.display('${date.year}', digits);
    if (locale.languageCode == 'ckb') {
      return '$dayی ${_ckbMonths[date.month - 1]}ی $year';
    }
    if (locale.languageCode == 'ar') {
      return '$day ${_arMonths[date.month - 1]} $year';
    }
    return '$day ${_enMonths[date.month - 1]} $year';
  }

  /// Time of day on the 24-hour clock, "14:05", in the chosen digit style
  /// and LTR-isolated.
  static String time(DateTime date, {required DigitStyle digits}) {
    String two(int v) => v.toString().padLeft(2, '0');
    return Bidi.ltr(
      Digits.display('${two(date.hour)}:${two(date.minute)}', digits),
    );
  }
}
