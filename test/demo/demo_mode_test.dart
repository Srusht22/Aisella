import 'dart:async';

import 'package:aisellia/app/app.dart';
import 'package:aisellia/app/route_guard.dart';
import 'package:aisellia/core/config/app_config.dart';
import 'package:aisellia/core/settings/key_value_store.dart';
import 'package:aisellia/demo/demo_mode.dart';
import 'package:aisellia/features/orders/presentation/order_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/test_app.dart';

void main() {
  tearDown(() => demoMode.value = false);

  testWidgets('a test build offers the guest demo on Welcome', (tester) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(signedIn: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try as a guest'));
    await tester.pumpAndSettle();
    // The plans come first; the guest entry is at the bottom.
    expect(find.text('Choose your plan'), findsOneWidget);
    expect(find.text('Business'), findsOneWidget);
    await tester.tap(find.text('Continue as a guest'));
    expect(demoMode.value, isTrue);
  });

  testWidgets('starting the trial from the plans leads to sign-up', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(signedIn: false, planChosen: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try as a guest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Starter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start 7-day free trial'));
    await tester.pumpAndSettle();
    expect(find.text('Create your account'), findsOneWidget);
    expect(demoMode.value, isFalse);
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

  Future<void> openDemo(WidgetTester tester) async {
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
  }

  GoRouter router(WidgetTester tester) =>
      GoRouter.of(tester.element(find.byType(Scaffold).first));

  testWidgets('an order shows its customer chat and replies from the app', (
    tester,
  ) async {
    await openDemo(tester);
    unawaited(router(tester).push(Routes.order('order-1006')));
    await tester.pumpAndSettle();
    final chat = find.byType(OrderChat);
    await tester.scrollUntilVisible(
      chat,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(chat, findsOneWidget);
    expect(find.textContaining('بۆنی عود'), findsWidgets);
    final box = find.descendant(
      of: find.byType(OrderChat),
      matching: find.byType(TextField),
    );
    await tester.ensureVisible(box);
    await tester.enterText(box, 'Yes, it is available.');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('Reply sent'), findsOneWidget);
    expect(find.textContaining('Yes, it is available.'), findsWidgets);
  });

  testWidgets('Connections shows the connected accounts and drivers', (
    tester,
  ) async {
    await openDemo(tester);
    unawaited(router(tester).push(Routes.connections));
    await tester.pumpAndSettle();
    expect(find.textContaining('@shilan.boutique'), findsOneWidget);
    expect(find.text('Not connected'), findsWidgets);
    expect(find.textContaining('Aram'), findsOneWidget);
  });
}
