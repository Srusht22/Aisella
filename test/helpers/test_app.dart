import 'package:aisellia/app/app.dart';
import 'package:aisellia/core/config/app_config.dart';
import 'package:aisellia/core/settings/key_value_store.dart';
import 'package:aisellia/features/products/data/products_repository.dart';
import 'package:aisellia/features/today/data/today_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the real app with test overrides: in-memory preferences, chosen
/// language and zero-latency repositories. No network, no real data.
Widget testApp({
  String? locale = 'en',
  bool sampleData = true,
  Map<String, String> extraPrefs = const {},
  TodayRepository? today,
  ProductsRepository? products,
}) {
  final store = InMemoryStore({'settings.locale': ?locale, ...extraPrefs});
  return ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(
        AppConfig(environment: AppEnvironment.dev, sampleData: sampleData),
      ),
      keyValueStoreProvider.overrideWithValue(store),
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
}) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

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
