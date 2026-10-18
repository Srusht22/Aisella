import 'package:aisellia/core/settings/app_settings.dart';
import 'package:aisellia/core/settings/key_value_store.dart';
import 'package:aisellia/design_system/theme/accents.dart';
import 'package:aisellia/design_system/theme/theme_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('Welcome opens Appearance; a colour theme applies and is kept', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(signedIn: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Royal Gold'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Appearance updated'), findsOneWidget);

    final context = tester.element(find.byType(Scaffold).first);
    expect(context.palette.brandPrimary, accentSeeds[AppAccent.gold]!.light);
    final container = ProviderScope.containerOf(context);
    expect(
      container.read(keyValueStoreProvider).read('settings.accent'),
      'gold',
    );
  });

  testWidgets('closing without Apply puts the previous look back', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(signedIn: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emerald'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    expect(context.palette.brandPrimary, accentSeeds[AppAccent.emerald]!.light);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      tester.element(find.byType(Scaffold).first).palette.brandPrimary,
      accentSeeds[AppAccent.ledger]!.light,
    );
  });
}
