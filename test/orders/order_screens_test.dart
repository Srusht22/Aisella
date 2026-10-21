import 'package:aisellia/app/router.dart';
import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/core/config/features.dart';
import 'package:aisellia/design_system/components/app_button.dart';
import 'package:aisellia/features/orders/domain/order.dart';
import 'package:aisellia/features/orders/presentation/order_detail_screen.dart';
import 'package:aisellia/features/orders/presentation/order_sheets.dart';
import 'package:aisellia/features/orders/presentation/orders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void _go(WidgetTester tester, String path) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(routerProvider)
        .go(path);

Future<void> _pump(
  WidgetTester tester,
  FakeOrdersRepository orders, {
  String? route,
  String locale = 'en',
  Size size = const Size(390, 844),
}) async {
  // Real glyph metrics: the test font is so wide that action bars squeeze.
  await loadAppFonts();
  setScreen(tester, size: size);
  await tester.pumpWidget(
    testApp(orders: orders, sampleData: false, locale: locale),
  );
  await tester.pumpAndSettle();
  if (route != null) {
    _go(tester, route);
    await tester.pumpAndSettle();
  }
}

final _isolates = RegExp(
  '[${String.fromCharCode(0x2066)}-${String.fromCharCode(0x2069)}]',
);

/// Text equal to [text] once bidi isolates are removed.
Finder _t(String text) => find.byWidgetPredicate((w) {
  final data = w is Text ? (w.data ?? w.textSpan?.toPlainText()) : null;
  return data != null && data.replaceAll(_isolates, '') == text;
});

/// Text containing [text] once bidi isolates are removed.
Finder _has(String text) => find.byWidgetPredicate((w) {
  final data = w is Text ? (w.data ?? w.textSpan?.toPlainText()) : null;
  return data != null && data.replaceAll(_isolates, '').contains(text);
});

Future<void> _tap(WidgetTester tester, Finder f) async {
  // A confirmation snackbar covers the action bar: dismiss it first.
  for (final m in tester.stateList<ScaffoldMessengerState>(
    find.byType(ScaffoldMessenger),
  )) {
    m.removeCurrentSnackBar();
  }
  await tester.pumpAndSettle();
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

/// The text field labelled [label] (AppTextField renders its label above).
Finder _field(String label) => find
    .descendant(
      of: find
          .ancestor(of: find.text(label), matching: find.byType(Column))
          .first,
      matching: find.byType(TextField),
    )
    .first;

Future<void> _enter(WidgetTester tester, String label, String text) async {
  await tester.ensureVisible(_field(label));
  await tester.enterText(_field(label), text);
  await tester.pump();
}

/// Opens the approval sheet and waits past its input guard.
Future<void> _openApprove(WidgetTester tester) async {
  await tester.tap(find.text('Approve order'));
  await tester.pumpAndSettle();
  await tester.pump(kApproveInputGuard);
}

int _stock(FakeOrdersRepository orders, String variantId) => orders.catalog
    .productOfVariant(variantId)!
    .variants
    .firstWhere((v) => v.id == variantId)
    .stockOnHand;

FakeOrdersRepository _repo() => FakeOrdersRepository(
  catalog: FakeCatalogRepository(products: sampleCatalog()),
);

void main() {
  group('Order list (OR-01)', () {
    testWidgets('no orders: says so and offers New order', (tester) async {
      await _pump(tester, _repo(), route: Routes.orders);
      expect(find.text('No orders yet'), findsOneWidget);
      expect(find.text('New order'), findsOneWidget);
    });

    testWidgets(
      'rows read as one sentence; filters and search hit the server',
      (tester) async {
        final orders = sampleOrders();
        await _pump(tester, orders, route: Routes.orders);
        expect(find.text('6 orders'), findsOneWidget);
        expect(_t('#1006'), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            RegExp(r'Order .*#1006.*Needs approval.*Nzar Ahmad'),
          ),
          findsOneWidget,
        );

        await _tap(tester, find.textContaining('Needs approval ·'));
        expect(orders.calls.last, 'list:needsApproval:');
        expect(_t('#1006'), findsOneWidget);
        expect(_t('#1004'), findsNothing);

        await _tap(tester, find.text('All'));
        // Typing does not send a request per keystroke (debounced).
        final before = orders.calls.length;
        await tester.enterText(find.byType(TextField).first, '0750 111');
        await tester.pump(const Duration(milliseconds: 100));
        expect(orders.calls.length, before);
        await tester.pumpAndSettle(const Duration(milliseconds: 400));
        expect(orders.calls.last, 'list:all:0750 111');
        expect(_t('#1006'), findsOneWidget);
        expect(_t('#1003'), findsOneWidget, reason: 'same phone number');
        expect(_t('#1001'), findsNothing);
      },
    );

    testWidgets('a failed load shows Retry, never an empty list', (
      tester,
    ) async {
      final orders = sampleOrders()
        ..failOn = 'list'
        ..failNext = const ApiException(ApiErrorCode.network);
      await _pump(tester, orders, route: Routes.orders);
      expect(find.text('Retry'), findsOneWidget);
      await _tap(tester, find.text('Retry'));
      expect(_t('#1006'), findsOneWidget);
    });

    testWidgets('tablet: list and detail side by side', (tester) async {
      await _pump(
        tester,
        sampleOrders(),
        route: Routes.orders,
        size: const Size(1280, 800),
      );
      expect(find.text('Select an order to see it here'), findsOneWidget);
      await _tap(tester, _has('Karwan Ali'));
      expect(find.byType(OrderDetailScreen), findsOneWidget);
      expect(find.byType(OrdersScreen), findsOneWidget);
      expect(_t('Order #1003'), findsOneWidget);
    });
  });

  group('Review and the approval gate (OR-02, OR-03)', () {
    testWidgets('a draft cannot be approved: missing details are listed', (
      tester,
    ) async {
      await _pump(tester, sampleOrders(), route: Routes.order('order-1005'));
      expect(find.text('Draft — not confirmed'), findsOneWidget);
      expect(find.text('4 things to check'), findsOneWidget);
      expect(find.textContaining('Phone number is missing'), findsOneWidget);
      expect(
        find.text('Complete the missing details to approve'),
        findsOneWidget,
      );
      final button = tester.widget<AppButton>(
        find.widgetWithText(AppButton, 'Approve order'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets(
      'approval only through the sheet: guarded, once, with the stock change',
      (tester) async {
        final orders = sampleOrders();
        await _pump(tester, orders, route: Routes.order('order-1006'));
        expect(_stock(orders, 'p-abaya-v0'), 10);
        expect(_t('10 in stock'), findsOneWidget);

        await tester.tap(find.text('Approve order'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(_t('Approve order #1006?'), findsOneWidget);
        expect(_t('Black Abaya: 10 → 8'), findsOneWidget);
        expect(
          find.textContaining('The customer is not messaged automatically'),
          findsOneWidget,
        );
        // Taps in the first 400 ms are ignored (no pass-through double tap).
        await tester.tap(find.text('Confirm approval'));
        await tester.pump();
        expect(orders.calls.where((c) => c.startsWith('approve')), isEmpty);

        await tester.pump(kApproveInputGuard);
        await tester.tap(find.text('Confirm approval'));
        await tester.tap(find.text('Confirm approval'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(
          orders.calls.where((c) => c.startsWith('approve')),
          hasLength(1),
        );
        expect(_stock(orders, 'p-abaya-v0'), 8);
        expect(
          _has('Order approved · Stock: Black Abaya 10 → 8'),
          findsOneWidget,
        );
        expect(find.text('Approved'), findsWidgets);
        expect(find.text('Mark as preparing'), findsOneWidget);
        expect(find.text('Approve order'), findsNothing);
      },
    );

    testWidgets('Back closes the sheet and nothing is approved', (
      tester,
    ) async {
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.order('order-1006'));
      await _openApprove(tester);
      await _tap(tester, find.text('Back'));
      expect(orders.calls.where((c) => c.startsWith('approve')), isEmpty);
      expect(find.text('Needs approval'), findsOneWidget);
      expect(_stock(orders, 'p-abaya-v0'), 10);
    });

    testWidgets('a changed price must be chosen explicitly (BR-23)', (
      tester,
    ) async {
      final orders = sampleOrders();
      orders.catalog.setPriceElsewhere('p-abaya', 38000);
      await _pump(tester, orders, route: Routes.order('order-1006'));
      expect(_has('Price now 38,000 IQD'), findsOneWidget);
      await _openApprove(tester);
      expect(
        find.text('Prices changed since this order was made'),
        findsOneWidget,
      );
      final confirm = find.text('Confirm approval');
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(orders.calls.where((c) => c.startsWith('approve')), isEmpty);

      await _tap(tester, _has('Current 38,000 IQD'));
      expect(
        _has('96,000 IQD'),
        findsOneWidget,
        reason: '2 × 38,000 + 15,000 + 5,000',
      );
      await _tap(tester, confirm);
      final approved = await orders.getOrder('s', 'order-1006');
      expect(approved.status, OrderStatus.approved);
      expect(approved.lines.first.approvedUnitPrice, 38000);
    });

    testWidgets('stock that ran out meanwhile: refused, nothing changes', (
      tester,
    ) async {
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.order('order-1006'));
      // Another device sold the abayas after the screen loaded.
      orders.catalog.setStockElsewhere('p-abaya', 1);
      await _openApprove(tester);
      await _tap(tester, find.text('Confirm approval'));
      expect(
        find.text('1 item doesn’t have enough stock. Nothing was approved.'),
        findsOneWidget,
      );
      expect(
        (await orders.getOrder('s', 'order-1006')).status,
        OrderStatus.pendingApproval,
      );
      expect(_stock(orders, 'p-abaya-v0'), 1);
    });

    testWidgets('approved on another device: reported, not approved twice', (
      tester,
    ) async {
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.order('order-1006'));
      await orders.approve(
        's',
        'order-1006',
        expectedVersion: 1,
        idempotencyKey: 'other-device',
      );
      await _openApprove(tester);
      await _tap(tester, find.text('Confirm approval'));
      expect(
        find.text('This order was already approved. Nothing changed.'),
        findsOneWidget,
      );
      expect(_stock(orders, 'p-abaya-v0'), 8, reason: 'deducted once');
    });

    testWidgets('a lost answer is retried with the same key: one approval', (
      tester,
    ) async {
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.order('order-1006'));
      await _openApprove(tester);
      orders.failNext = const ApiException(ApiErrorCode.timeout);
      await _tap(tester, find.text('Confirm approval'));
      expect(orders.calls.where((c) => c.startsWith('approve')), hasLength(2));
      expect(_stock(orders, 'p-abaya-v0'), 8);
      expect(
        (await orders.getOrder('s', 'order-1006')).status,
        OrderStatus.approved,
      );
    });

    testWidgets('reject needs a reason; it changes no stock', (tester) async {
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.order('order-1006'));
      await _tap(tester, find.text('Reject'));
      await _tap(tester, find.text('Reject draft'));
      expect(find.text('Choose a reason'), findsOneWidget);
      expect(orders.calls.where((c) => c.startsWith('reject')), isEmpty);
      await _tap(tester, find.text('Other'));
      await _tap(tester, find.text('Reject draft'));
      expect(find.text('Add a short note for Other'), findsOneWidget);
      await _tap(tester, find.text('Duplicate'));
      await _tap(tester, find.text('Reject draft'));
      expect(orders.calls, contains('reject:order-1006:duplicate'));
      expect(find.text('Draft rejected'), findsOneWidget);
      expect(find.text('Rejected'), findsWidgets);
      expect(_stock(orders, 'p-abaya-v0'), 10);
    });
  });

  group('After approval (OR-05, OR-08, OR-09, OR-10)', () {
    testWidgets('Preparing is the last step: no delivery actions follow', (
      tester,
    ) async {
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.order('order-1004'));
      expect(
        find.bySemanticsLabel(RegExp('Step 1 of 2, Approved')),
        findsOneWidget,
      );
      expect(find.text('Mark out for delivery'), findsNothing);
      await _tap(tester, find.text('Mark as preparing'));
      expect(find.text('Marked as preparing'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Step 2 of 2, Preparing')),
        findsOneWidget,
      );
      expect(find.text('Mark out for delivery'), findsNothing);
      expect(find.text('Mark delivered'), findsNothing);
    });

    testWidgets('an order already out for delivery offers no delivery steps', (
      tester,
    ) async {
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.order('order-1003'));
      expect(find.text('Delivery failed'), findsNothing);
      expect(find.text('Mark delivered'), findsNothing);
    });

    testWidgets(
      'prepare, dispatch, deliver with part of the cash, record the rest',
      (tester) async {
        final orders = sampleOrders();
        await _pump(tester, orders, route: Routes.order('order-1004'));
        expect(
          find.bySemanticsLabel(RegExp('Step 1 of 4, Approved')),
          findsOneWidget,
        );
        await _tap(tester, find.text('Mark as preparing'));
        expect(find.text('Marked as preparing'), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp('Step 2 of 4, Preparing')),
          findsOneWidget,
        );

        await _tap(tester, find.text('Mark out for delivery'));
        await _enter(tester, 'Courier or driver (optional)', 'Karwan');
        await _tap(tester, find.text('Mark out for delivery').last);
        expect(orders.calls, contains('transition:order-1004:dispatched'));
        expect(find.text('Marked as out for delivery'), findsOneWidget);
        expect(find.text('Cancel order'), findsNothing);

        await _tap(tester, find.text('Mark delivered'));
        await _tap(tester, find.text('Partly'));
        await _enter(tester, 'Amount collected', '٢٠٠٠٠');
        await _tap(tester, find.text('Mark delivered').last);
        final delivered = await orders.getOrder('s', 'order-1004');
        expect(delivered.status, OrderStatus.delivered);
        expect(delivered.codCollected, 20000);
        expect(delivered.codOutstanding, 20000);

        await _tap(tester, find.text('Record cash'));
        await _tap(tester, find.text('Record cash').last);
        expect(find.text('Cash recorded'), findsOneWidget);
        expect((await orders.getOrder('s', 'order-1004')).codOutstanding, 0);
        expect(find.text('Record cash'), findsNothing);
      },
      // Delivery tracking is off (owner decision); kept for when it returns.
      skip: !Features.deliveryTracking,
    );

    testWidgets('cancel restocks once and closes the order', (tester) async {
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.order('order-1004'));
      final before = _stock(orders, 'p-abaya-v0');
      await _tap(tester, find.byTooltip('More actions'));
      await _tap(tester, find.text('Cancel order'));
      expect(_has('these go back to stock: 1 × Black Abaya'), findsOneWidget);
      await _tap(tester, find.text('Customer cancelled'));
      await _tap(tester, find.text('Cancel order').last);
      expect(find.text('Order cancelled'), findsOneWidget);
      expect(_stock(orders, 'p-abaya-v0'), before + 1);
      expect(find.text('Cancelled'), findsWidgets);
      expect(find.text('Mark as preparing'), findsNothing);
    });

    testWidgets('delivery failed then returned: each line decided', (
      tester,
    ) async {
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.order('order-1003'));
      await _tap(tester, find.text('Delivery failed'));
      await _tap(tester, find.text('Refused'));
      await _tap(tester, find.text('Mark delivery failed'));
      expect(find.text('Marked as delivery failed'), findsOneWidget);
      await _tap(tester, find.text('Mark returned'));
      final button = find.widgetWithText(AppButton, 'Mark returned').last;
      await _tap(tester, button);
      expect(
        orders.calls.where((c) => c.startsWith('return')),
        isEmpty,
        reason: 'no default decision',
      );
      await _tap(tester, find.text('Restock'));
      expect(_t('3 back to stock, 0 written off'), findsOneWidget);
      await _tap(tester, button);
      expect(find.text('Marked as returned'), findsOneWidget);
      expect(
        (await orders.getOrder('s', 'order-1003')).status,
        OrderStatus.returned,
      );
    }, skip: !Features.deliveryTracking);

    testWidgets('confirmation is copied by the seller, never "sent"', (
      tester,
    ) async {
      String? clip;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clip = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.order('order-1004'));
      await _tap(tester, find.byTooltip('More actions'));
      await _tap(tester, find.text('Copy confirmation message'));
      await _tap(tester, find.text('Copy message'));
      expect(clip, contains('#1004'));
      expect(find.text('Copied — not confirmed as sent'), findsOneWidget);
      expect(find.textContaining('Sent'), findsNothing);
      await _tap(tester, find.text('I sent this'));
      expect(orders.calls, contains('marked:order-1004'));
    });
  });

  group('Editor (OR-06, OR-07)', () {
    testWidgets('a new manual order is saved as a draft, never approved', (
      tester,
    ) async {
      final orders = _repo();
      await _pump(tester, orders, route: Routes.orders);
      await _tap(tester, find.text('New order').first);
      await _enter(tester, 'Name', 'Nzar Ahmad');
      await _enter(tester, 'Phone', '٠٧٥٠ ١١١ ٢٢٣٣');
      await _tap(tester, _has('Erbil · 5,000 IQD'));
      await _enter(tester, 'Area or district', 'Ankawa');

      await _tap(tester, find.text('Add item'));
      await _tap(tester, _has('Linen Shirt'));
      // The out-of-stock size is shown but cannot be chosen.
      final m = find.ancestor(
        of: _has('M · Out of stock'),
        matching: find.byType(ChoiceChip),
      );
      expect(tester.widget<ChoiceChip>(m).onSelected, isNull);
      await _tap(tester, _has('L ·'));
      await _tap(tester, find.byTooltip('Increase'));
      await _tap(tester, find.text('Add to order'));
      expect(_has('Linen Shirt · L'), findsOneWidget);
      expect(
        _has('55,000 IQD'),
        findsOneWidget,
        reason: 'estimate 2 × 25,000 + 5,000',
      );

      await _tap(tester, find.text('Save as draft'));
      expect(orders.calls, contains('create'));
      expect(find.text('Order saved. It needs your approval.'), findsOneWidget);
      final created = await orders.getOrder('s', 'order-1001');
      expect(created.status, OrderStatus.pendingApproval);
      expect(created.customerPhone, '+9647501112233');
      expect(created.approvedAt, isNull);
      expect(find.text('Approve order'), findsOneWidget);
    });

    testWidgets('invalid values are shown on the field; nothing is sent', (
      tester,
    ) async {
      final orders = _repo();
      await _pump(tester, orders, route: Routes.orderNew);
      await _enter(tester, 'Phone', '12345');
      await _tap(tester, find.text('Save as draft'));
      expect(find.text('1 field needs attention'), findsOneWidget);
      expect(
        find.textContaining('Enter an Iraqi mobile number'),
        findsOneWidget,
      );
      expect(orders.calls, isNot(contains('create')));
    });

    testWidgets('editing an approved order shows the stock difference', (
      tester,
    ) async {
      final orders = sampleOrders();
      await _pump(tester, orders, route: Routes.orderEdit('order-1004'));
      expect(find.textContaining('Item changes move stock'), findsOneWidget);
      await _tap(tester, find.byTooltip('Increase'));
      expect(_has('Stock on save: −1'), findsOneWidget);
      final before = _stock(orders, 'p-abaya-v0');
      await _tap(tester, find.text('Save changes'));
      expect(_has('Changes saved · stock changed for 1 item'), findsOneWidget);
      expect(_stock(orders, 'p-abaya-v0'), before - 1);
    });

    testWidgets('a dispatched order cannot be edited', (tester) async {
      await _pump(
        tester,
        sampleOrders(),
        route: Routes.orderEdit('order-1003'),
      );
      expect(find.text("This order can't be edited"), findsOneWidget);
    });
  });

  group('History, access and language', () {
    testWidgets('history lists every status change', (tester) async {
      await _pump(
        tester,
        sampleOrders(),
        route: Routes.orderHistory('order-1003'),
      );
      expect(find.text('Created as Needs approval'), findsOneWidget);
      expect(find.text('Needs approval → Approved'), findsOneWidget);
      expect(find.text('Approved → Out for delivery'), findsOneWidget);
    });

    testWidgets("another store's order id shows unavailable", (tester) async {
      await _pump(tester, sampleOrders(), route: Routes.order('not-mine'));
      expect(find.text('This order isn’t available'), findsOneWidget);
      expect(find.text('Approve order'), findsNothing);
    });

    testWidgets('Sorani: right-to-left review with Western-digit numbers', (
      tester,
    ) async {
      await _pump(
        tester,
        sampleOrders(),
        route: Routes.order('order-1006'),
        locale: 'ckb',
      );
      expect(
        Directionality.of(tester.element(find.byType(OrderDetailScreen))),
        TextDirection.rtl,
      );
      expect(_has('#1006'), findsWidgets);
      expect(find.text('پەسەندکردنی داواکاری'), findsOneWidget);
      expect(_has('+964 750 111 2233'), findsOneWidget);
    });
  });
}
