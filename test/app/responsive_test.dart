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
      // Draft review: totals and actions remain present.
      final ordersLabel = locale == 'en' ? 'Orders' : 'داواکارییەکان';
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(ordersLabel),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byType(OutlinedButton).hitTestable().evaluate().isEmpty
            ? find.textContaining(
                locale == 'en' ? 'Preview the draft' : 'پێشبینینی',
              )
            : find.byType(OutlinedButton),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
