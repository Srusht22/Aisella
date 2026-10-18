import 'package:aisellia/app/app.dart';
import 'package:aisellia/core/config/app_config.dart';
import 'package:aisellia/core/settings/key_value_store.dart';
import 'package:aisellia/demo/demo_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  tearDown(() => demoMode.value = false);

  testWidgets('a test build offers the guest demo on Welcome', (tester) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(signedIn: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try as a guest'));
    expect(demoMode.value, isTrue);
  });

  testWidgets('production never offers the guest demo', (tester) async {
    setScreen(tester);
    await tester.pumpWidget(
      testApp(signedIn: false, environment: AppEnvironment.prod),
    );
    await tester.pumpAndSettle();
    expect(find.text('Try as a guest'), findsNothing);
  });

  testWidgets('the demo opens a seeded store and sign-out leaves it', (
    tester,
  ) async {
    setScreen(tester);
    demoMode.value = true;
    await tester.pumpWidget(
      DemoSwitch(
        realOverrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(
              environment: AppEnvironment.staging,
              sampleData: false,
            ),
          ),
          keyValueStoreProvider.overrideWithValue(
            InMemoryStore({'settings.locale': 'en'}),
          ),
        ],
        child: const AiselliaApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('DEMO'), findsOneWidget);

    await tester.tap(find.text('Orders').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Nzar Ahmad'), findsWidgets);

    await tester.tap(find.text('Inbox').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Shilan'), findsWidgets);
  });
}
