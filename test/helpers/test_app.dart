import 'package:aisellia/app/app.dart';
import 'package:aisellia/core/clock.dart';
import 'package:aisellia/core/config/app_config.dart';
import 'package:aisellia/core/settings/key_value_store.dart';
import 'package:aisellia/features/auth/application/auth_controller.dart';
import 'package:aisellia/features/catalog/data/catalog_repository.dart';
import 'package:aisellia/features/catalog/data/media_store.dart';
import 'package:aisellia/features/orders/data/orders_repository.dart';
import 'package:aisellia/features/store/application/workspace_controller.dart';
import 'package:aisellia/features/store/domain/store.dart';
import 'package:aisellia/features/today/data/today_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fakes.dart';
import 'fakes.dart';
import 'order_fakes.dart';

export 'catalog_fakes.dart';
export 'fakes.dart';
export 'order_fakes.dart';

/// Builds the real app with test overrides: in-memory preferences, chosen
/// language, fake auth and store backends, zero-latency repositories.
/// By default a verified seller is signed in with a fully set-up store.
/// The clock is fixed so screens that show today's date render identically
/// on every day (the goldens depend on it).
Widget testApp({
  String? locale = 'en',
  bool sampleData = true,
  AppEnvironment environment = AppEnvironment.dev,
  Map<String, String> extraPrefs = const {},
  TodayRepository? today,
  FakeCatalogRepository? catalog,
  FakeOrdersRepository? orders,
  FakeMediaStore? media,
  FakePhotoPicker? picker,
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
  final catalogRepo = orders?.catalog ?? catalog ?? FakeCatalogRepository();
  final prefs = InMemoryStore({'settings.locale': ?locale, ...extraPrefs});
  return ProviderScope(
    overrides: [
      clockProvider.overrideWithValue(() => testNow),
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
                : null),
      ),
      catalogRepositoryProvider.overrideWithValue(catalogRepo),
      ordersRepositoryProvider.overrideWithValue(
        orders ?? FakeOrdersRepository(catalog: catalogRepo),
      ),
      mediaStoreProvider.overrideWithValue(media ?? FakeMediaStore()),
      photoPickerProvider.overrideWithValue(picker ?? FakePhotoPicker()),
      // The real pipeline, run synchronously (no isolates in widget tests).
      imagePreparerProvider.overrideWithValue(
        (bytes) async =>
            prepareProductImageSync(bytes) ??
            (throw const MediaException(MediaFailure.unsupported)),
      ),
    ],
    child: const AiselliaApp(),
  );
}

/// The fixed "now" of widget and golden tests: Thursday, 15 October 2026.
final testNow = DateTime(2026, 10, 15, 10);

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
