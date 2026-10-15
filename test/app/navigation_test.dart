import 'package:aisellia/app/router.dart';
import 'package:aisellia/features/inbox/inbox_screen.dart';
import 'package:aisellia/features/onboarding/language_selection_screen.dart';
import 'package:aisellia/features/orders/presentation/orders_home_screen.dart';
import 'package:aisellia/features/products/presentation/products_screen.dart';
import 'package:aisellia/features/today/presentation/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/test_app.dart';

GoRouter _router(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(routerProvider);

void main() {
  testWidgets('first launch shows language selection, then Today', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp(locale: null));
    await tester.pumpAndSettle();
    expect(find.byType(LanguageSelectionScreen), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.byType(TodayScreen), findsOneWidget);
  });

  testWidgets('tabs switch content and mark the selected destination', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    expect(find.byType(TodayScreen), findsOneWidget);

    for (final (label, screen) in [
      ('Inbox', InboxScreen),
      ('Orders', OrdersHomeScreen),
      ('Products', ProductsScreen),
    ]) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(screen), findsOneWidget, reason: label);
    }
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 3);
  });

  testWidgets('each tab keeps its own stack; re-selecting pops to root', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Orders'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview the draft review screen'));
    await tester.pumpAndSettle();
    expect(find.text('Draft — not confirmed'), findsOneWidget);

    // Switch away and back: the Orders stack is preserved.
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Today'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Orders'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Draft — not confirmed'), findsOneWidget);

    // Re-selecting the active tab returns to its root.
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Orders'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OrdersHomeScreen), findsOneWidget);
    expect(find.text('Draft — not confirmed'), findsNothing);
  });

  testWidgets('system back at a non-Today tab root goes to Today', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Products'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TodayScreen), findsOneWidget);
  });

  testWidgets('store menu opens and deferred rows lead to an honest screen', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Store menu'));
    await tester.pumpAndSettle();
    expect(find.text('Store'), findsOneWidget);
    await tester.tap(find.text('Delivery zones'));
    await tester.pumpAndSettle();
    expect(find.text("Delivery zones isn't available yet"), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Store'), findsOneWidget);
  });

  testWidgets('unknown routes show not-found with a way back', (tester) async {
    setScreen(tester);
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    _router(tester).go('/does-not-exist');
    await tester.pumpAndSettle();
    expect(find.text("This page isn't available"), findsOneWidget);
    await tester.tap(find.text('Go to Today'));
    await tester.pumpAndSettle();
    expect(find.byType(TodayScreen), findsOneWidget);
  });

  testWidgets('repeated taps on a tab do not stack duplicate pages', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    final products = find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Products'),
    );
    for (var i = 0; i < 4; i++) {
      await tester.tap(products);
    }
    await tester.pumpAndSettle();
    expect(find.byType(ProductsScreen), findsOneWidget);
  });
}
