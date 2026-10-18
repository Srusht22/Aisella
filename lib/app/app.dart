import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/l10n/supported_locales.dart';
import '../core/settings/app_settings.dart';
import '../demo/demo_mode.dart';
import '../design_system/motion/motion.dart';
import '../design_system/theme/app_theme.dart';
import 'environment_ribbon.dart';
import 'localization_setup.dart';
import 'router.dart';

/// Root widget: theme (light/dark per preference), locale (Sorani/English),
/// motion preference and router.
class AiselliaApp extends ConsumerWidget {
  const AiselliaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final config = ref.watch(appConfigProvider);
    final router = ref.watch(routerProvider);
    final locale =
        settings.locale ??
        SupportedLocales.suggestFor(
          WidgetsBinding.instance.platformDispatcher.locales,
        );

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (_) => 'Aisellia',
      routerConfig: router,
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      theme: buildAppTheme(brightness: Brightness.light, locale: locale),
      darkTheme: buildAppTheme(brightness: Brightness.dark, locale: locale),
      themeMode: switch (settings.theme) {
        ThemePreference.system => ThemeMode.system,
        ThemePreference.light => ThemeMode.light,
        ThemePreference.dark => ThemeMode.dark,
      },
      builder: (context, child) => MotionScope(
        reduce: settings.motion == MotionPreference.reduce,
        child: EnvironmentRibbon(
          environment: config.environment,
          demo: ref.watch(isDemoProvider),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}
