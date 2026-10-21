import 'package:aisellia/app/router.dart';
import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/core/config/features.dart';
import 'package:aisellia/design_system/components/app_button.dart';
import 'package:aisellia/features/fulfilment/domain/fulfilment.dart';
import 'package:aisellia/features/orders/domain/order.dart';
import 'package:aisellia/features/orders/domain/order_draft.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void _go(WidgetTester tester, String path) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(routerProvider)
        .go(path);

final _isolates = RegExp(
  '[${String.fromCharCode(0x2066)}-${String.fromCharCode(0x2069)}]',
);

Finder _has(String text) => find.byWidgetPredicate((w) {
  final data = w is Text
      ? (w.data ?? w.textSpan?.toPlainText())
      : w is SelectableText
      ? (w.data ?? w.textSpan?.toPlainText())
      : null;
  return data != null && data.replaceAll(_isolates, '').contains(text);
});

Finder _button(String label) => find.widgetWithText(AppButton, label);

Future<void> _tap(WidgetTester tester, Finder f) async {
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

Future<void> _pump(
  WidgetTester tester, {
  required FakeOrdersRepository orders,
  required FakeFulfilmentRepository fulfilment,
  required String route,
  String locale = 'en',
  Size size = const Size(390, 844),
}) async {
  await loadAppFonts();
  setScreen(tester, size: size);
  await tester.pumpWidget(
    testApp(
      orders: orders,
      fulfilment: fulfilment,
      sampleData: false,
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
  _go(tester, route);
  await tester.pumpAndSettle();
}

FakeOrdersRepository _orders() => FakeOrdersRepository(
  catalog: FakeCatalogRepository(products: sampleCatalog()),
);

const _karwan = Courier(
  id: 'courier-k',
  name: 'Karwan',
  active: true,
  version: 1,
);

OrderDraft _paidOther() => const OrderDraft(
  customerName: 'Shilan Hama',
  customerPhone: '+9647701234567',
  zoneId: 'zone-1',
  area: 'Ankawa',
  paymentMethod: PaymentMethod.other,
  lines: [
    DraftLine(
      variantId: 'p-abaya-v0',
      name: '',
      label: '',
      unitPrice: 0,
      quantity: 1,
    ),
  ],
);

void main() {
  group('Domain', () {
    test('a courier, a delivery list and its stops parse from the server', () {
      final c = Courier.fromJson({
        'id': 'c1',
        'name': 'Karwan',
        'phone': '+9647701234567',
        'active': true,
        'version': 2,
        'owed': 85000,
        'owed_orders': 2,
        'carrying': 40000,
        'carrying_orders': 1,
      });
      expect([c.owed, c.owedOrders, c.carryingOrders], [85000, 2, 1]);
      final l = DeliveryList.fromJson({
        'id': 'l1',
        'number': 3,
        'status': 'handed_over',
        'version': 4,
        'courier': {'id': 'c1', 'name': 'Karwan'},
        'order_count': 1,
        'cod_total': 40000,
        'created_at': '2026-10-15T09:00:00Z',
        'handed_over_at': '2026-10-15T10:00:00Z',
        'stops': [
          {
            'order_id': 'o1',
            'number': 1042,
            'status': 'dispatched',
            'customer_name': 'Nzar',
            'phone': '+9647501112233',
            'zone': 'Erbil',
            'area': 'Ankawa',
            'cash_to_collect': 40000,
            'total': 40000,
            'currency': 'IQD',
            'issues': <Object>[],
            'items': [
              {'name': 'Abaya', 'variant': '', 'quantity': 2},
            ],
          },
        ],
      });
      expect(l.status, DeliveryListStatus.handedOver);
      expect(l.isOpen, isFalse);
      expect(l.stops.single.items.single.variant, isNull);
      expect(l.stops.single.complete, isTrue);
      expect(
        PaymentChannel.parse('bank_transfer'),
        PaymentChannel.bankTransfer,
      );
      expect(PaymentChannel.parse('bitcoin'), PaymentChannel.other);
    });

    test('an order carries its courier, payments and delivery list', () {
      final repo = _orders();
      final seeded = repo.seed(_paidOther(), status: 'approved');
      repo.overlays[seeded.id] = {
        'courier': {'id': 'c1', 'name': 'Karwan'},
        'paid_total': 10000,
        'payments': [
          {
            'method': 'zaincash',
            'amount': 10000,
            'reference': 'ZC-1',
            'recorded_at': '2026-10-15T09:00:00Z',
          },
        ],
        'delivery_list': {'id': 'l1', 'number': 3, 'status': 'open'},
      };
      return repo.getOrder('s', seeded.id).then((o) {
        expect(
          [o.courierName, o.paidTotal, o.deliveryListNumber],
          ['Karwan', 10000, 3],
        );
        expect(o.payments.single.method, 'zaincash');
      });
    });
  });

  group('Couriers', () {
    testWidgets(
      'add a courier: name required, Iraqi phone checked, duplicates refused',
      (tester) async {
        final orders = _orders();
        final f = FakeFulfilmentRepository(orders: orders);
        await _pump(
          tester,
          orders: orders,
          fulfilment: f,
          route: Routes.storeCouriers,
        );
        expect(_has('No couriers yet.'), findsOneWidget);
        await _tap(tester, _button('Add courier'));
        await _tap(tester, _button('Save'));
        expect(_has("Enter the courier's name"), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('courier-name')),
            matching: find.byType(TextField),
          ),
          'Karwan',
        );
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('courier-phone')),
            matching: find.byType(TextField),
          ),
          '12345',
        );
        await _tap(tester, _button('Save'));
        expect(_has('Enter an Iraqi mobile number'), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('courier-phone')),
            matching: find.byType(TextField),
          ),
          '0770 123 4567',
        );
        await _tap(tester, _button('Save'));
        expect(f.calls, contains('saveCourier:Karwan:+9647701234567:true'));
        expect(_has('Karwan'), findsOneWidget);
        expect(
          _has('Owes nothing'),
          findsNothing,
        ); // cash hidden: orders stop at Preparing

        await _tap(tester, _button('Add courier'));
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('courier-name')),
            matching: find.byType(TextField),
          ),
          'karwan',
        );
        await _tap(tester, _button('Save'));
        expect(
          _has('You already have a courier with this name.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('without delivery tracking a courier card shows no cash', (
      tester,
    ) async {
      final orders = _orders();
      final f = FakeFulfilmentRepository(
        orders: orders,
        couriers: [
          const Courier(
            id: 'c1',
            name: 'Karwan',
            active: true,
            version: 1,
            owed: 90000,
            owedOrders: 2,
          ),
        ],
      );
      await _pump(
        tester,
        orders: orders,
        fulfilment: f,
        route: Routes.storeCouriers,
      );
      expect(_has('Karwan'), findsOneWidget);
      expect(_has('Owes 90,000'), findsNothing);
      expect(_button('Record cash handed over'), findsNothing);
    });

    testWidgets(
      'cash a courier hands over is never more than owed',
      (tester) async {
        final orders = _orders();
        final f = FakeFulfilmentRepository(
          orders: orders,
          couriers: [
            const Courier(
              id: 'c1',
              name: 'Karwan',
              active: true,
              version: 1,
              owed: 90000,
              owedOrders: 2,
            ),
          ],
        );
        await _pump(
          tester,
          orders: orders,
          fulfilment: f,
          route: Routes.storeCouriers,
        );
        expect(_has('Owes 90,000'), findsWidgets);
        await _tap(tester, _button('Record cash handed over'));
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('settle-amount')),
            matching: find.byType(TextField),
          ),
          '95000',
        );
        await _tap(tester, _button('Record cash handed over').last);
        expect(_has('This is more than what is due.'), findsOneWidget);
        expect(f.calls.where((c) => c.startsWith('settle')), isEmpty);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('settle-amount')),
            matching: find.byType(TextField),
          ),
          '90000',
        );
        await _tap(tester, _button('Record cash handed over').last);
        expect(f.calls, contains('settle:c1:90000'));
        expect(_has('Owes nothing'), findsOneWidget);
      },
      // Courier cash exists only with delivery tracking, which is off.
      skip: !Features.deliveryTracking,
    );

    testWidgets('the store menu opens connections, then drivers', (
      tester,
    ) async {
      final orders = _orders();
      await _pump(
        tester,
        orders: orders,
        fulfilment: FakeFulfilmentRepository(orders: orders),
        route: Routes.store,
      );
      await _tap(tester, _has('Connections'));
      expect(_has('No drivers yet.'), findsOneWidget);
      await _tap(tester, _has('Add or manage drivers'));
      expect(_has('No couriers yet.'), findsOneWidget);
    });
  });

  group('Delivery lists', () {
    testWidgets(
      'ready orders become a list, copied as text, then handed over in one step',
      (tester) async {
        final orders = _orders();
        final o1 = orders.seed(
          completeOrder(name: 'Nzar Ahmad'),
          status: 'approved',
        );
        final o2 = orders.seed(
          completeOrder(name: 'Dara Kamal', phone: '+9647501112244'),
          status: 'approved',
        );
        orders.seed(completeOrder(name: 'Waiting One'));
        final f = FakeFulfilmentRepository(orders: orders, couriers: [_karwan]);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await _pump(
          tester,
          orders: orders,
          fulfilment: f,
          route: Routes.deliveryLists,
        );
        expect(_has('2 orders are ready to go'), findsOneWidget);

        await _tap(tester, _button('New delivery list'));
        await _tap(tester, find.byKey(const ValueKey('courier-courier-k')));
        await _tap(tester, find.byKey(ValueKey('ready-${o1.id}')));
        await _tap(tester, find.byKey(ValueKey('ready-${o2.id}')));
        await _tap(tester, _button('Create list'));
        expect(f.calls, contains('createList:courier-k:${o1.id},${o2.id}'));
        expect(_has('Delivery list 1'), findsWidgets);
        expect(_has('Nzar Ahmad'), findsOneWidget);
        expect(_has('To collect: 50,000'), findsWidgets);

        await _tap(tester, _button('Copy list'));
        expect(copied, contains('#${o1.number}'));
        expect(copied, contains('750 111 2244'));
        expect(copied, contains('Cash to collect: 100,000'));
        expect(
          copied,
          isNot(contains(String.fromCharCode(0x2066))),
          reason: 'plain text for a chat app',
        );

        await _tap(tester, _button('Hand over to courier'));
        expect(
          _has('All 2 orders are marked out for delivery with Karwan.'),
          findsOneWidget,
        );
        await _tap(
          tester,
          find.descendant(
            of: find.byType(AlertDialog),
            matching: _button('Hand over to courier'),
          ),
        );
        expect(f.calls, contains('updateList:hand_over:-'));
        expect(
          [orders.raw(o1.id)['status'], orders.raw(o2.id)['status']],
          ['dispatched', 'dispatched'],
        );
        expect(_has('Handed over'), findsWidgets);
      },
    );

    testWidgets('without a courier a list cannot be handed over', (
      tester,
    ) async {
      final orders = _orders();
      final o1 = orders.seed(completeOrder(), status: 'approved');
      final f = FakeFulfilmentRepository(orders: orders, couriers: [_karwan]);
      await _pump(
        tester,
        orders: orders,
        fulfilment: f,
        route: Routes.deliveryLists,
      );
      await _tap(tester, _button('New delivery list'));
      await _tap(tester, find.byKey(ValueKey('ready-${o1.id}')));
      await _tap(tester, _button('Create list'));
      expect(
        _has('Choose a courier before handing the list over.'),
        findsOneWidget,
      );
      expect(
        tester.widget<AppButton>(_button('Hand over to courier')).onPressed,
        isNull,
      );
    });

    testWidgets('an order that can no longer go blocks the whole hand-over', (
      tester,
    ) async {
      final orders = _orders();
      final o1 = orders.seed(
        completeOrder(name: 'Nzar Ahmad'),
        status: 'approved',
      );
      final o2 = orders.seed(
        completeOrder(name: 'Dara Kamal'),
        status: 'approved',
      );
      final f = FakeFulfilmentRepository(orders: orders, couriers: [_karwan]);
      await _pump(
        tester,
        orders: orders,
        fulfilment: f,
        route: Routes.deliveryLists,
      );
      await _tap(tester, _button('New delivery list'));
      await _tap(tester, find.byKey(const ValueKey('courier-courier-k')));
      await _tap(tester, find.byKey(ValueKey('ready-${o1.id}')));
      await _tap(tester, find.byKey(ValueKey('ready-${o2.id}')));
      await _tap(tester, _button('Create list'));
      orders.raw(o2.id)['status'] =
          'cancelled'; // cancelled elsewhere meanwhile
      await _tap(tester, _button('Hand over to courier'));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: _button('Hand over to courier'),
        ),
      );
      expect(
        _has('These orders cannot go out: #${o2.number}.'),
        findsOneWidget,
      );
      expect(orders.raw(o1.id)['status'], 'approved', reason: 'all or nothing');

      // Removing the blocked order lets the rest go.
      await _tap(tester, _button('Remove from list').last);
      expect(f.calls, contains('updateList:set_orders:courier-k'));
    });

    for (final locale in ['ckb', 'ar']) {
      testWidgets('a delivery list lays out right to left in $locale', (
        tester,
      ) async {
        final orders = _orders();
        final o1 = orders.seed(
          completeOrder(name: 'ڕێزان عومەر'),
          status: 'approved',
        );
        final f = FakeFulfilmentRepository(orders: orders, couriers: [_karwan]);
        final list = await f.createDeliveryList(
          's',
          courierId: 'courier-k',
          orderIds: [o1.id],
          idempotencyKey: 'k',
        );
        await _pump(
          tester,
          orders: orders,
          fulfilment: f,
          route: Routes.deliveryList(list.id),
          locale: locale,
          size: const Size(320, 640),
        );
        expect(tester.takeException(), isNull);
        expect(
          Directionality.of(tester.element(find.byType(Scaffold).first)),
          TextDirection.rtl,
        );
      });
    }
  });

  group('Payments', () {
    testWidgets(
      'a transfer is recorded on an order paid "other", never above the total',
      (tester) async {
        final orders = _orders();
        final o = orders.seed(_paidOther(), status: 'approved');
        final f = FakeFulfilmentRepository(orders: orders);
        await _pump(
          tester,
          orders: orders,
          fulfilment: f,
          route: Routes.order(o.id),
        );
        await _tap(tester, _button('Record payment'));
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('payment-amount')),
            matching: find.byType(TextField),
          ),
          '${o.total + 1}',
        );
        await _tap(tester, _button('Record payment').last);
        expect(_has('This is more than what is due.'), findsOneWidget);
        await _tap(tester, find.widgetWithText(ChoiceChip, 'ZainCash'));
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('payment-amount')),
            matching: find.byType(TextField),
          ),
          '10000',
        );
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('payment-reference')),
            matching: find.byType(TextField),
          ),
          'ZC-77',
        );
        await _tap(tester, _button('Record payment').last);
        expect(f.calls, contains('payment:${o.id}:zaincash:10000:ZC-77'));
        expect(_has('ZainCash'), findsWidgets);
        expect(_has('Left to pay'), findsOneWidget);
      },
    );

    testWidgets('cash-on-delivery orders do not offer transfers', (
      tester,
    ) async {
      final orders = _orders();
      final o = orders.seed(completeOrder(), status: 'approved');
      await _pump(
        tester,
        orders: orders,
        fulfilment: FakeFulfilmentRepository(orders: orders),
        route: Routes.order(o.id),
      );
      expect(_button('Record payment'), findsNothing);
    });

    test(
      'the fake refuses a payment above the total, like the server',
      () async {
        final orders = _orders();
        final o = orders.seed(_paidOther(), status: 'approved');
        final f = FakeFulfilmentRepository(orders: orders);
        expect(
          () => f.recordPayment(
            's',
            o.id,
            method: PaymentChannel.fib,
            amount: o.total + 1,
            idempotencyKey: 'k',
          ),
          throwsA(isA<ApiException>()),
        );
      },
    );
  });
}
