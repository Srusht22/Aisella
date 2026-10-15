// Kurdish Sorani (ckb) localizations for Flutter's built-in widgets.
//
// Verified in Phase 4: Flutter 3.47.7 ships no `ckb` Widgets, Material or
// Cupertino localizations, and `intl` 0.20.3 has no `ckb` date data. Without
// these delegates a `ckb` app would fall back to LTR and English system text.
//
// * Widgets: complete, RTL.
// * Material/Cupertino: extend the English bundles and override every string
//   reachable from the P0 UI (tooltips, text-selection menu, sheets, dialogs,
//   search, refresh). Strings for date/time pickers and other unused widgets
//   remain English — documented in docs/implementation/phase-4.
//
// All Sorani strings are machine-drafted and pending native review (DD-04).
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' as intl;

bool _isCkb(Locale locale) => locale.languageCode == 'ckb';

/// The English `DateFormat`s below need intl's date data. Flutter's Global
/// delegates load it, but they never run for `ckb`, so a cold start in
/// Sorani would throw `LocaleDataException`. Loading local data completes
/// synchronously and is idempotent.
void _ensureDateData() {
  if (_dateDataLoaded) return;
  initializeDateFormatting('en');
  _dateDataLoaded = true;
}

bool _dateDataLoaded = false;

class CkbWidgetsLocalizations extends GlobalWidgetsLocalizations {
  const CkbWidgetsLocalizations() : super(TextDirection.rtl);

  static const LocalizationsDelegate<WidgetsLocalizations> delegate =
      _CkbWidgetsDelegate();

  @override
  String get copyButtonLabel => 'لەبەرگرتنەوە';
  @override
  String get cutButtonLabel => 'بڕین';
  @override
  String get lookUpButtonLabel => 'گەڕان بەدوایدا';
  @override
  String get noResultsFound => 'هیچ ئەنجامێک نەدۆزرایەوە';
  @override
  String get pasteButtonLabel => 'لکاندن';
  @override
  String get radioButtonUnselectedLabel => 'دیاری نەکراوە';
  @override
  String get reorderItemDown => 'بیبە بۆ خوارەوە';
  @override
  String get reorderItemLeft => 'بیبە بۆ چەپ';
  @override
  String get reorderItemRight => 'بیبە بۆ ڕاست';
  @override
  String get reorderItemToEnd => 'بیبە بۆ کۆتایی';
  @override
  String get reorderItemToStart => 'بیبە بۆ سەرەتا';
  @override
  String get reorderItemUp => 'بیبە بۆ سەرەوە';
  @override
  String get searchResultsFound => 'ئەنجامی گەڕان دۆزرایەوە';
  @override
  String get searchWebButtonLabel => 'گەڕان لە وێب';
  @override
  String get selectAllButtonLabel => 'هەمووی دیاری بکە';
  @override
  String get shareButtonLabel => 'هاوبەشکردن';
}

class _CkbWidgetsDelegate extends LocalizationsDelegate<WidgetsLocalizations> {
  const _CkbWidgetsDelegate();

  @override
  bool isSupported(Locale locale) => _isCkb(locale);

  @override
  Future<WidgetsLocalizations> load(Locale locale) =>
      SynchronousFuture(const CkbWidgetsLocalizations());

  @override
  bool shouldReload(_CkbWidgetsDelegate old) => false;
}

class CkbMaterialLocalizations extends MaterialLocalizationEn {
  CkbMaterialLocalizations()
    : super(
        localeName: 'ckb',
        fullYearFormat: intl.DateFormat.y('en'),
        compactDateFormat: intl.DateFormat.yMd('en'),
        shortDateFormat: intl.DateFormat.yMMMd('en'),
        mediumDateFormat: intl.DateFormat.MMMEd('en'),
        longDateFormat: intl.DateFormat.yMMMMEEEEd('en'),
        yearMonthFormat: intl.DateFormat.yMMMM('en'),
        shortMonthDayFormat: intl.DateFormat.MMMd('en'),
        decimalFormat: intl.NumberFormat.decimalPattern('en'),
        twoDigitZeroPaddedFormat: intl.NumberFormat('00', 'en'),
      );

  static const LocalizationsDelegate<MaterialLocalizations> delegate =
      _CkbMaterialDelegate();

  @override
  ScriptCategory get scriptCategory => ScriptCategory.tall;
  @override
  int get firstDayOfWeekIndex => 6; // Saturday
  @override
  String get backButtonTooltip => 'گەڕانەوە';
  @override
  String get closeButtonTooltip => 'داخستن';
  @override
  String get closeButtonLabel => 'داخستن';
  @override
  String get cancelButtonLabel => 'هەڵوەشاندنەوە';
  @override
  String get okButtonLabel => 'باشە';
  @override
  String get continueButtonLabel => 'بەردەوامبوون';
  @override
  String get copyButtonLabel => 'لەبەرگرتنەوە';
  @override
  String get cutButtonLabel => 'بڕین';
  @override
  String get pasteButtonLabel => 'لکاندن';
  @override
  String get selectAllButtonLabel => 'هەمووی دیاری بکە';
  @override
  String get lookUpButtonLabel => 'گەڕان بەدوایدا';
  @override
  String get searchWebButtonLabel => 'گەڕان لە وێب';
  @override
  String get shareButtonLabel => 'هاوبەشکردن';
  @override
  String get deleteButtonTooltip => 'سڕینەوە';
  @override
  String get moreButtonTooltip => 'زیاتر';
  @override
  String get searchFieldLabel => 'گەڕان';
  @override
  String get clearButtonTooltip => 'پاککردنەوە';
  @override
  String get modalBarrierDismissLabel => 'لابردن';
  @override
  String get dialogLabel => 'دیالۆگ';
  @override
  String get alertDialogLabel => 'ئاگاداری';
  @override
  String get bottomSheetLabel => 'پەڕەی خوارەوە';
  @override
  String get scrimLabel => 'پەردە';
  @override
  String get showMenuTooltip => 'پیشاندانی لیست';
  @override
  String get refreshIndicatorSemanticLabel => 'نوێکردنەوە';
  @override
  String get viewLicensesButtonLabel => 'بینینی مۆڵەتەکان';
  @override
  String get licensesPageTitle => 'مۆڵەتەکان';
  @override
  String get keyboardKeyEscape => 'Esc';
}

class _CkbMaterialDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _CkbMaterialDelegate();

  @override
  bool isSupported(Locale locale) => _isCkb(locale);

  @override
  Future<MaterialLocalizations> load(Locale locale) {
    _ensureDateData();
    return SynchronousFuture(CkbMaterialLocalizations());
  }

  @override
  bool shouldReload(_CkbMaterialDelegate old) => false;
}

class CkbCupertinoLocalizations extends CupertinoLocalizationEn {
  CkbCupertinoLocalizations()
    : super(
        localeName: 'ckb',
        fullYearFormat: intl.DateFormat.y('en'),
        dayFormat: intl.DateFormat.d('en'),
        weekdayFormat: intl.DateFormat('EEE', 'en'),
        mediumDateFormat: intl.DateFormat.MMMEd('en'),
        singleDigitHourFormat: intl.DateFormat('HH', 'en'),
        singleDigitMinuteFormat: intl.DateFormat.m('en'),
        doubleDigitMinuteFormat: intl.DateFormat('mm', 'en'),
        singleDigitSecondFormat: intl.DateFormat.s('en'),
        decimalFormat: intl.NumberFormat.decimalPattern('en'),
      );

  static const LocalizationsDelegate<CupertinoLocalizations> delegate =
      _CkbCupertinoDelegate();

  @override
  String get copyButtonLabel => 'لەبەرگرتنەوە';
  @override
  String get cutButtonLabel => 'بڕین';
  @override
  String get pasteButtonLabel => 'لکاندن';
  @override
  String get selectAllButtonLabel => 'هەمووی دیاری بکە';
  @override
  String get lookUpButtonLabel => 'گەڕان بەدوایدا';
  @override
  String get searchWebButtonLabel => 'گەڕان لە وێب';
  @override
  String get shareButtonLabel => 'هاوبەشکردن';
  @override
  String get searchTextFieldPlaceholderLabel => 'گەڕان';
  @override
  String get modalBarrierDismissLabel => 'لابردن';
  @override
  String get clearButtonLabel => 'پاککردنەوە';
  @override
  String get cancelButtonLabel => 'هەڵوەشاندنەوە';
  @override
  String get backButtonLabel => 'گەڕانەوە';
}

class _CkbCupertinoDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const _CkbCupertinoDelegate();

  @override
  bool isSupported(Locale locale) => _isCkb(locale);

  @override
  Future<CupertinoLocalizations> load(Locale locale) {
    _ensureDateData();
    return SynchronousFuture(CkbCupertinoLocalizations());
  }

  @override
  bool shouldReload(_CkbCupertinoDelegate old) => false;
}
