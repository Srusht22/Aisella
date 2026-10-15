import 'package:flutter/widgets.dart';

import '../../l10n/gen/app_localizations.dart';

export '../../l10n/gen/app_localizations.dart' show AppLocalizations;

extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
