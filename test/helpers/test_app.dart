import 'package:aisellia/app/app.dart';
import 'package:aisellia/core/config/app_config.dart';
import 'package:aisellia/core/settings/key_value_store.dart';
import 'package:aisellia/features/auth/application/auth_controller.dart';
import 'package:aisellia/features/products/data/products_repository.dart';
import 'package:aisellia/features/store/application/workspace_controller.dart';
import 'package:aisellia/features/store/domain/store.dart';
import 'package:aisellia/features/today/data/today_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

export 'fakes.dart';

/// Builds the real app with test overrides: in-memory preferences, chosen
/// language, fake auth and store backends, zero-latency repositories.
/// By default a verified seller is signed in with a fully set-up store.
Widget testApp({
  String? locale = 'en',
  bool sampleData = true,
  AppEnvironment environment = AppEnvironment.dev,
  Map<String, String> extraPrefs = const {},
  TodayRepository? today,
  ProductsRepository? products,
  FakeAuthRepository? auth,
  FakeStoreRepository? storeBackend,
  bool signedIn = true,
  Store? store,
}) {
  final authRepo =
      auth ?? FakeAuthRepository(initialUser: signedIn ? testUser : null);
  final storeRepo =
      storeBackend ??
      FakeStoreRepository(store: store ?? testStore(), zones: [_zone]);
  final prefs = InMemoryStore({'settings.locale': ?locale, ...extraPrefs});
  return ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(
        AppConfig(environment: environment, sampleData: sampleData),
      ),
      keyValueStoreProvider.overrideWithValue(prefs),
      authRepositoryProvider.overrideWithValue(authRepo),
      storeRepositoryProvider.overrideWithValue(storeRepo),
      todayRepositoryProvider.overrideWithValue(
        today ??
            (sampleData
                ? const SampleTodayRepository(latency: Duration.zero)
                : const NotConnectedTodayRepository()),
      ),
      productsRepositoryProvider.overrideWithValue(
        products ??
            (sampleData
                ? const SampleProductsRepository(latency: Duration.zero)
                : const NotConnectedProductsRepository()),
      ),
    ],
    child: const AiselliaApp(),
  );
}

/// Sets the logical screen size and text scale for one test.
void setScreen(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1.0,
  double devicePixelRatio = 3,
}) {
  tester.view.physicalSize = size * devicePixelRatio;
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

const _zone = DeliveryZone(
  id: 'zone-1',
  name: 'Erbil',
  fee: 5000,
  timeText: null,
  version: 1,
);

bool _fontsLoaded = false;

/// Loads the bundled fonts so goldens and layout tests use real glyph
/// metrics (Inter, Vazirmatn NL, Phosphor) instead of the test font.
Future<void> loadAppFonts() async {
  if (_fontsLoaded) return;
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(rootBundle.load(f));
    }
    await loader.load();
  }

  await family('Inter', [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      'assets/fonts/inter/Inter-$w.ttf',
  ]);
  await family('VazirmatnNL', [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      'assets/fonts/vazirmatn/Vazirmatn-NL-$w.ttf',
  ]);
  await family('PhosphorRegular', [
    'assets/fonts/phosphor/Phosphor-subset.ttf',
  ]);
  await family('PhosphorFill', [
    'assets/fonts/phosphor/Phosphor-Fill-subset.ttf',
  ]);
  _fontsLoaded = true;
}
