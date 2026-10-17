import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

Future<void> _visitAll(WidgetTester tester, {required bool rail}) async {
  final labels = ['Inbox', 'Orders', 'Products', 'Today'];
  for (final label in labels) {
    final scope = rail
        ? find.byType(NavigationRail)
        : find.byType(NavigationBar);
    await tester.tap(find.descendant(of: scope, matching: find.text(label)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'overflow on $label');
  }
}

void main() {
  for (final (name, size, rail) in [
    ('small phone 320x568', const Size(320, 568), false),
    ('phone 390x844', const Size(390, 844), false),
    ('tablet portrait 768x1024', const Size(768, 1024), true),
    ('tablet landscape 1280x800', const Size(1280, 800), true),
  ]) {
    testWidgets('$name uses ${rail ? 'rail' : 'bottom bar'} without overflow', (
      tester,
    ) async {
      setScreen(tester, size: size);
      await tester.pumpWidget(testApp());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), rail ? findsOneWidget : findsNothing);
      expect(find.byType(NavigationBar), rail ? findsNothing : findsOneWidget);
      await _visitAll(tester, rail: rail);
    });
  }

  for (final locale in ['en', 'ckb']) {
    testWidgets('200% text on a small phone does not overflow ($locale)', (
      tester,
    ) async {
      await loadAppFonts();
      setScreen(tester, size: const Size(360, 640), textScale: 2.0);
      await tester.pumpWidget(testApp(locale: locale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Orders: the list, a draft review with totals and actions, the
      // approval sheet and the editor all fit.
      await tester.pumpWidget(testApp(locale: locale, orders: sampleOrders()));
      await tester.pumpAndSettle();
      final ordersLabel = locale == 'en' ? 'Orders' : 'داواکاری';
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(ordersLabel),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.textContaining('Nzar Ahmad'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Nzar Ahmad'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.text(locale == 'en' ? 'Approve order' : 'پەسەندکردنی داواکاری'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('navigation labels cap text scale; page content does not', (
    tester,
  ) async {
    await loadAppFonts();
    setScreen(tester, textScale: 2.0);
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    final nav = find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Products'),
    );
    expect(MediaQuery.textScalerOf(tester.element(nav)).scale(10), 13);
    final body = find.text('Sample data');
    expect(MediaQuery.textScalerOf(tester.element(body)).scale(10), 20);
  });
}
