import 'package:aisellia/app/router.dart';
import 'package:aisellia/features/store/domain/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void _go(WidgetTester tester, String path) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(routerProvider)
        .go(path);

void main() {
  testWidgets('Sorani sign-in is RTL while email and password stay LTR', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(locale: 'ckb', signedIn: false));
    await tester.pumpAndSettle();
    _go(tester, Routes.signIn);
    await tester.pumpAndSettle();
    final title = find.text('بەخێربێیتەوە');
    expect(title, findsOneWidget);
    expect(Directionality.of(tester.element(title)), TextDirection.rtl);
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.textDirection, TextDirection.ltr);
    }
    expect(find.text('چوونەژوورەوە'), findsWidgets);
  });

  testWidgets('Sorani store setup is RTL with Sorani labels; phone stays LTR', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(
      testApp(locale: 'ckb', storeBackend: FakeStoreRepository()),
    );
    await tester.pumpAndSettle();
    expect(find.text('هەنگاوی 1 لە 3'), findsOneWidget);
    expect(find.text('ناوی فرۆشگا'), findsOneWidget);
    expect(find.text('هەولێر'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.text('ناوی فرۆشگا'))),
      TextDirection.rtl,
    );
    final phone = tester
        .widgetList<TextField>(find.byType(TextField))
        .elementAt(1);
    expect(phone.textDirection, TextDirection.ltr);
  });

  for (final locale in ['en', 'ckb']) {
    testWidgets('200% text: auth and setup screens do not overflow ($locale)', (
      tester,
    ) async {
      await loadAppFonts();
      setScreen(tester, size: const Size(360, 640), textScale: 2.0);

      await tester.pumpWidget(testApp(locale: locale, signedIn: false));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'welcome');
      for (final route in [
        Routes.signIn,
        Routes.signUp,
        Routes.forgotPassword,
      ]) {
        _go(tester, route);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: route);
      }
      _go(tester, '${Routes.verifyEmail}?email=seller%40example.test');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'verify');
      // Let the resend countdown finish so no timer is left running.
      await tester.pump(const Duration(seconds: 61));

      for (final step in [
        null,
        OnboardingStep.zones,
        OnboardingStep.payments,
      ]) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          testApp(
            locale: locale,
            storeBackend: FakeStoreRepository(
              store: step == null ? null : testStore(step: step),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'setup $step');
      }
    });
  }
}
