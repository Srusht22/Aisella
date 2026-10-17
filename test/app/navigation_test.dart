import 'package:aisellia/app/router.dart';
import 'package:aisellia/core/config/app_config.dart';
import 'package:aisellia/features/catalog/presentation/product_list_screen.dart';
import 'package:aisellia/features/inbox/inbox_screen.dart';
import 'package:aisellia/features/onboarding/language_selection_screen.dart';
import 'package:aisellia/features/orders/presentation/orders_screen.dart';
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
      ('Orders', OrdersScreen),
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
    await tester.pumpWidget(testApp(orders: sampleOrders()));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Orders'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Nzar Ahmad'));
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
    expect(find.byType(OrdersScreen), findsOneWidget);
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
    await tester.tap(find.text('Customers'));
    await tester.pumpAndSettle();
    expect(find.text("Customers isn't available yet"), findsOneWidget);
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

  testWidgets('the debug gallery route does not exist in production', (
    tester,
  ) async {
    setScreen(tester);
    await tester.pumpWidget(
      testApp(environment: AppEnvironment.prod, sampleData: false),
    );
    await tester.pumpAndSettle();
    _router(tester).go(Routes.storeGallery);
    await tester.pumpAndSettle();
    expect(find.text("This page isn't available"), findsOneWidget);
  });

  testWidgets('no screen renders an icon from a font the app does not bundle', (
    tester,
  ) async {
    // uses-material-design is false: Material/Cupertino icon glyphs would
    // render as empty boxes. Only the vendored Phosphor fonts are bundled.
    const bundled = {'PhosphorRegular', 'PhosphorFill'};
    void expectOnlyBundledIcons(String where) {
      for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
        expect(bundled, contains(icon.icon?.fontFamily), reason: where);
      }
    }

    setScreen(tester);
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    for (final route in [
      Routes.today,
      Routes.inbox,
      Routes.orders,
      '/orders/order-1006',
      Routes.products,
      Routes.store,
      Routes.storeLanguage,
      Routes.storeGallery,
    ]) {
      _router(tester).go(route);
      // Fixed pumps: the gallery's skeleton pulse repeats forever.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expectOnlyBundledIcons(route);
    }
    _router(tester).go(Routes.store);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.scrollUntilVisible(find.text('Legal and licences'), 100);
    await tester.tap(find.text('Legal and licences'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(LicensePage), findsOneWidget);
    expectOnlyBundledIcons('licenses');
  });
}
