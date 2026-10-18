import 'package:aisellia/core/formatting/dates.dart';
import 'package:aisellia/core/formatting/money.dart';
import 'package:aisellia/core/l10n/supported_locales.dart';
import 'package:aisellia/core/settings/app_settings.dart';
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

  testWidgets('Arabic renders right-to-left with Arabic labels', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(locale: 'ar'));
    await tester.pumpAndSettle();
    final ctx = tester.element(find.byType(TodayScreen));
    expect(Directionality.of(ctx), TextDirection.rtl);
    expect(find.text('المنتجات'), findsOneWidget); // Products tab
    // System strings come from Flutter's own Arabic delegate.
    expect(MaterialLocalizations.of(ctx).backButtonTooltip, 'رجوع');
    // Section labels are not uppercased or tracked in Arabic script either.
    final label = tester.widget<Text>(find.text('يحتاج إلى انتباه'));
    expect(label.style?.letterSpacing ?? 0, 0);
  });

  test('Arabic dates and amounts', () {
    const ar = Locale('ar');
    expect(
      Dates.dayMonthYear(
        DateTime(2026, 10, 29),
        locale: ar,
        digits: DigitStyle.western,
      ),
      '29 تشرين الأول 2026',
    );
    expect(
      Dates.weekdayDayMonth(
        DateTime(2026, 10, 15),
        locale: ar,
        digits: DigitStyle.eastern,
      ),
      'الخميس، ١٥ تشرين الأول',
    );
    expect(
      Money.format(
        35000,
        Currency.iqd,
        locale: ar,
        digits: DigitStyle.western,
      ).replaceAll(RegExp('[\u2066-\u2069]'), ''),
      '35,000 د.ع',
    );
    expect(SupportedLocales.suggestFor(const [Locale('ar', 'IQ')]), ar);
    expect(
      SupportedLocales.suggestFor(const [Locale('fr')]),
      SupportedLocales.ckb,
    );
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
    // Arabic is offered too.
    await tester.tap(find.text('العربية'));
    await tester.pumpAndSettle();
    expect(find.text('اللغة والعرض'), findsOneWidget);
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
