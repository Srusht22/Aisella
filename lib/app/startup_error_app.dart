import 'package:flutter/material.dart';

import '../core/l10n/l10n.dart';
import '../core/l10n/supported_locales.dart';
import '../design_system/components/feedback.dart';
import '../design_system/icons/app_icons.dart';
import '../design_system/theme/app_theme.dart';
import 'localization_setup.dart';

/// Shown when the build configuration is invalid. Plain language only; the
/// technical reason is logged for developers, never displayed.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      localeResolutionCallback: (device, supported) =>
          SupportedLocales.suggestFor([?device]),
      theme: buildAppTheme(
        brightness: Brightness.light,
        locale: SupportedLocales.en,
      ),
      home: Builder(
        builder: (context) {
          final locale = Localizations.localeOf(context);
          return Theme(
            data: buildAppTheme(brightness: Brightness.light, locale: locale),
            child: Scaffold(
              body: SafeArea(
                child: EmptyState(
                  icon: AppIcons.warningCircle,
                  title: context.l10n.startupErrorTitle,
                  body: context.l10n.startupErrorBody,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
