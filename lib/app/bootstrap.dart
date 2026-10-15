import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/settings/key_value_store.dart';
import 'app.dart';
import 'startup_error_app.dart';

/// Initialises the app. Configuration errors show a startup error screen
/// instead of crashing; unavailable preference storage degrades to in-memory
/// preferences for the session.
Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerFontLicenses();

  final AppConfig config;
  try {
    config = AppConfig.fromEnvironment();
  } on AppConfigException catch (e) {
    // Developer-facing only; the user sees a plain-language screen.
    debugPrint(e.toString());
    runApp(const StartupErrorApp());
    return;
  }

  KeyValueStore store;
  try {
    store = await SharedPreferencesStore.open();
  } on Object catch (e) {
    debugPrint(
      'Preferences unavailable, using in-memory store: ${e.runtimeType}',
    );
    store = InMemoryStore();
  }

  runApp(
    ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        keyValueStoreProvider.overrideWithValue(store),
      ],
      child: const AiselliaApp(),
    ),
  );
}

/// Bundled fonts are SIL OFL 1.1 / MIT: their licences must ship with the
/// app and appear on the licences page (ST-10).
void _registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (pkg, path) in const [
      ('Inter', 'assets/fonts/inter/OFL.txt'),
      ('Vazirmatn', 'assets/fonts/vazirmatn/OFL.txt'),
      ('Phosphor Icons', 'assets/fonts/phosphor/LICENSE.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        pkg,
      ], await rootBundle.loadString(path));
    }
  });
}
