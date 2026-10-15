// Visual review goldens: representative screens with the real bundled fonts
// in English (LTR) and Sorani (RTL), light and dark, phone and tablet.
//
// Goldens are rendered by Flutter's test engine on Linux; text antialiasing
// differs slightly between operating systems, so they are tagged and can be
// excluded elsewhere with `flutter test -x golden`.
//
//   flutter test --tags golden                   # compare
//   flutter test --tags golden --update-goldens  # regenerate after review
@Tags(['golden'])
library;

import 'package:aisellia/app/router.dart';
import 'package:aisellia/features/store/domain/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

const _phone = Size(390, 844);
const _tablet = Size(1280, 800);

Future<void> _shot(
  WidgetTester tester, {
  required String name,
  required String? locale,
  String route = Routes.today,
  bool dark = false,
  Size size = _phone,
  double textScale = 1.0,
  Future<void> Function(WidgetTester)? before,
  bool signedIn = true,
  FakeStoreRepository? storeBackend,
}) async {
  await loadAppFonts();
  // flutter_test paints elevation as a solid black outline by default;
  // render real shadows so the review sees what users see.
  // Restored before the test ends: flutter_test checks it is unchanged.
  debugDisableShadows = false;
  try {
    await _render(
      tester,
      name,
      locale,
      route,
      dark,
      size,
      textScale,
      before,
      signedIn,
      storeBackend,
    );
  } finally {
    debugDisableShadows = true;
  }
}

Future<void> _render(
  WidgetTester tester,
  String name,
  String? locale,
  String route,
  bool dark,
  Size size,
  double textScale,
  Future<void> Function(WidgetTester)? before,
  bool signedIn,
  FakeStoreRepository? storeBackend,
) async {
  // 2x keeps the committed PNGs small while staying legible for review.
  setScreen(tester, size: size, textScale: textScale, devicePixelRatio: 2);
  await tester.pumpWidget(
    testApp(
      locale: locale,
      extraPrefs: {if (dark) 'settings.theme': 'dark'},
      signedIn: signedIn,
      storeBackend: storeBackend,
    ),
  );
  await tester.pumpAndSettle();
  if (locale != null && route != Routes.today && route != '') {
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(routerProvider)
        .go(route);
    await tester.pumpAndSettle();
  }
  if (before != null) await before(tester);
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  testWidgets(
    'language selection',
    (t) => _shot(t, name: 'language_light', locale: null),
  );

  for (final locale in ['en', 'ckb']) {
    for (final dark in [false, true]) {
      final theme = dark ? 'dark' : 'light';
      testWidgets('today $locale $theme', (t) {
        return _shot(
          t,
          name: 'today_${locale}_$theme',
          locale: locale,
          dark: dark,
        );
      });
      testWidgets('draft preview $locale $theme', (t) {
        return _shot(
          t,
          name: 'draft_${locale}_$theme',
          locale: locale,
          dark: dark,
          route: Routes.draftPreview,
        );
      });
    }
    testWidgets('products $locale', (t) {
      return _shot(
        t,
        name: 'products_${locale}_light',
        locale: locale,
        route: Routes.products,
      );
    });
    testWidgets('language and display $locale', (t) {
      return _shot(
        t,
        name: 'settings_${locale}_light',
        locale: locale,
        route: Routes.storeLanguage,
      );
    });
    testWidgets('tablet today $locale', (t) {
      return _shot(
        t,
        name: 'tablet_today_$locale',
        locale: locale,
        size: _tablet,
      );
    });
  }

  testWidgets('draft preview, full length, ckb', (t) {
    return _shot(
      t,
      name: 'draft_ckb_full',
      locale: 'ckb',
      route: Routes.draftPreview,
      size: const Size(390, 1500),
    );
  });

  testWidgets('draft preview at 200% text, ckb', (t) {
    return _shot(
      t,
      name: 'draft_ckb_text200',
      locale: 'ckb',
      route: Routes.draftPreview,
      size: const Size(360, 780),
      textScale: 2.0,
    );
  });

  testWidgets('today at 320 with 200% text, ckb', (t) {
    return _shot(
      t,
      name: 'today_ckb_320_text200',
      locale: 'ckb',
      size: const Size(320, 640),
      textScale: 2.0,
    );
  });

  testWidgets('products at small phone 320, en', (t) {
    return _shot(
      t,
      name: 'products_en_320',
      locale: 'en',
      route: Routes.products,
      size: const Size(320, 568),
    );
  });

  // Phase 5: authentication and store setup.
  testWidgets('welcome en', (t) {
    return _shot(
      t,
      name: 'p5_welcome_en',
      locale: 'en',
      signedIn: false,
      route: '',
    );
  });
  testWidgets('sign in ckb', (t) {
    return _shot(
      t,
      name: 'p5_sign_in_ckb',
      locale: 'ckb',
      signedIn: false,
      route: Routes.signIn,
    );
  });
  testWidgets('sign up en', (t) {
    return _shot(
      t,
      name: 'p5_sign_up_en',
      locale: 'en',
      signedIn: false,
      route: Routes.signUp,
    );
  });
  testWidgets('verify email ckb', (t) {
    return _shot(
      t,
      name: 'p5_verify_ckb',
      locale: 'ckb',
      signedIn: false,
      route: '${Routes.verifyEmail}?email=seller%40example.test',
      before: (t) async {
        // Stop the resend countdown timer once the frame is captured.
        addTearDown(() => t.pump(const Duration(seconds: 61)));
      },
    );
  });
  testWidgets('setup store ckb', (t) {
    return _shot(
      t,
      name: 'p5_setup_store_ckb',
      locale: 'ckb',
      route: '',
      storeBackend: FakeStoreRepository(),
    );
  });
  testWidgets('setup zones en', (t) {
    return _shot(
      t,
      name: 'p5_setup_zones_en',
      locale: 'en',
      route: '',
      storeBackend: FakeStoreRepository(
        store: testStore(step: OnboardingStep.zones),
      ),
      before: (t) async {
        await t.tap(find.text('Erbil'));
        await t.pumpAndSettle();
      },
    );
  });
  testWidgets('setup payments ckb dark', (t) {
    return _shot(
      t,
      name: 'p5_setup_payments_ckb_dark',
      locale: 'ckb',
      dark: true,
      route: '',
      storeBackend: FakeStoreRepository(
        store: testStore(step: OnboardingStep.payments),
      ),
    );
  });
  testWidgets('today checklist, no sample data, ckb', (t) {
    return _shot(
      t,
      name: 'p5_today_checklist_ckb',
      locale: 'ckb',
      route: '',
      storeBackend: FakeStoreRepository(store: testStore()),
    );
  });
}
