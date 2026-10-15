import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/l10n/ckb_localizations.dart';
import '../core/l10n/supported_locales.dart';
import '../l10n/gen/app_localizations.dart';

/// Delegate order matters: the custom `ckb` delegates come before Flutter's
/// global ones (which do not support `ckb`).
const List<LocalizationsDelegate<Object>> appLocalizationsDelegates = [
  AppLocalizations.delegate,
  CkbWidgetsLocalizations.delegate,
  CkbMaterialLocalizations.delegate,
  CkbCupertinoLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
];

const List<Locale> appSupportedLocales = SupportedLocales.all;
