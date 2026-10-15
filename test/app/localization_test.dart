import 'package:aisellia/features/today/presentation/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('Sorani renders right-to-left with Sorani labels', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(locale: 'ckb'));
    await tester.pumpAndSettle();
    final ctx = tester.element(find.byType(TodayScreen));
    expect(Directionality.of(ctx), TextDirection.rtl);
    expect(find.text('ئەمڕۆ'), findsWidgets); // Today
    expect(find.text('کاڵاکان'), findsOneWidget); // Products tab
    // System strings come from the custom ckb Material delegate, not English.
    expect(MaterialLocalizations.of(ctx).backButtonTooltip, 'گەڕانەوە');
  });

  testWidgets('English renders left-to-right', (tester) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(locale: 'en'));
    await tester.pumpAndSettle();
    final ctx = tester.element(find.byType(TodayScreen));
    expect(Directionality.of(ctx), TextDirection.ltr);
    expect(find.text('Needs attention'), findsNothing); // uppercased overline
    expect(find.text('NEEDS ATTENTION'), findsOneWidget);
  });

  testWidgets('Sorani section labels are never uppercased or tracked', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(locale: 'ckb'));
    await tester.pumpAndSettle();
    final label = tester.widget<Text>(find.text('پێویستی بە سەرنجە'));
    expect(label.style?.letterSpacing ?? 0, 0);
  });

  testWidgets('switching language in settings flips direction immediately', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(locale: 'en'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Store menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Language and display'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('کوردی (سۆرانی)'));
    await tester.pumpAndSettle();
    expect(find.text('زمان و پیشاندان'), findsOneWidget); // title now Sorani
    expect(
      Directionality.of(tester.element(find.text('زمان و پیشاندان'))),
      TextDirection.rtl,
    );
  });

  testWidgets('directional icons mirror in RTL; object icons do not', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(locale: 'ckb'));
    await tester.pumpAndSettle();
    // Attention rows end with a caret that must mirror (matchTextDirection).
    final icons = tester.widgetList<Icon>(find.byType(Icon));
    final caret = icons.firstWhere(
      (i) =>
          i.icon?.fontFamily == 'PhosphorRegular' && i.icon!.matchTextDirection,
    );
    expect(caret.icon!.matchTextDirection, isTrue);
    final house = icons.where((i) => i.icon?.fontFamily == 'PhosphorFill');
    expect(house.every((i) => !i.icon!.matchTextDirection), isTrue);
  });
}
