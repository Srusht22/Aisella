import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/features/orders/domain/order.dart';
import 'package:aisellia/features/orders/domain/order_draft.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> orderJson({
  String status = 'pending_approval',
  List<Map<String, dynamic>>? lines,
  List<Map<String, dynamic>> issues = const [],
}) => {
  'id': 'o1',
  'number': 1042,
  'status': status,
  'currency': 'IQD',
  'customer': {'name': 'Nzar Ahmad', 'phone': '+9647501112233', 'phone2': null},
  'delivery': {
    'zone_id': 'z1',
    'zone_name': 'Erbil',
    'area': 'Ankawa',
    'fee': 5000,
    'fee_source': 'zone',
  },
  'payment': {
    'method': 'cod',
    'cod_due': 0,
    'cod_collected': 0,
    'cod_outstanding': 0,
  },
  'discount': 0,
  'subtotal': 70000,
  'total': 75000,
  'approved_by': 'system',
  'approved_at': null,
  'version': 3,
  'created_at': '2026-10-15T08:00:00Z',
  'status_changed_at': '2026-10-15T08:00:00Z',
  'issues': issues,
  'events': [
    {
      'from': null,
      'to': 'pending_approval',
      'actor': 'you',
      'created_at': '2026-10-15T08:00:00Z',
    },
  ],
  'lines':
      lines ??
      [
        {
          'id': 'l1',
          'variant_id': 'v1',
          'product_id': 'p1',
          'name': 'Beige Abaya',
          'variant_label': 'M',
          'quantity': 2,
          'quoted_unit_price': 35000,
          'unit_price': 35000,
          'line_total': 70000,
          'stock_deducted': 0,
          'current': {
            'price': 35000,
            'stock_on_hand': 4,
            'track_stock': true,
            'available': true,
            'product_status': 'active',
            'variant_status': 'active',
          },
        },
      ],
};

Map<String, dynamic> line({
  int quantity = 2,
  int quoted = 35000,
  int price = 35000,
  int stock = 4,
  String productStatus = 'active',
  bool track = true,
  bool available = true,
}) => {
  'id': 'l1',
  'variant_id': 'v1',
  'name': 'Beige Abaya',
  'variant_label': 'M',
  'quantity': quantity,
  'quoted_unit_price': quoted,
  'unit_price': quoted,
  'line_total': quoted * quantity,
  'stock_deducted': 0,
  'current': {
    'price': price,
    'stock_on_hand': stock,
    'track_stock': track,
    'available': available,
    'product_status': productStatus,
    'variant_status': 'active',
  },
};

void main() {
  group('Order contract', () {
    test('parses the server shape', () {
      final o = Order.fromJson(orderJson());
      expect(o.number, 1042);
      expect(o.status, OrderStatus.pendingApproval);
      expect(o.place, 'Erbil');
      expect(o.feeFromSeller, isFalse);
      expect(o.approvedBy, isNull, reason: 'not approved: no approver');
      expect(o.lines.single.variantLabel, 'M');
      expect(o.events.single.actor, Actor.you);
      expect(o.canApprove, isTrue);
      expect(o.unitCount, 2);
    });

    test('approval is blocked in the UI by issues and unsellable lines', () {
      expect(
        Order.fromJson(
          orderJson(
            issues: [
              {'field': 'area', 'kind': 'missing'},
            ],
          ),
        ).canApprove,
        isFalse,
      );
      expect(
        Order.fromJson(orderJson(lines: [line(stock: 1)])).blockedLines,
        hasLength(1),
      );
      expect(
        Order.fromJson(orderJson(lines: [line(stock: 1)])).lines.single.shortBy,
        1,
      );
      expect(
        Order.fromJson(orderJson(lines: [line(productStatus: 'inactive')]))
            .lines
            .single
            .unavailable,
        isTrue,
      );
      expect(
        Order.fromJson(orderJson(lines: [line(track: false, available: false)]))
            .canApprove,
        isFalse,
      );
      expect(
        Order.fromJson(orderJson(lines: [line(track: false, stock: 0)]))
            .canApprove,
        isTrue,
        reason: 'untracked lines have no stock to run out of',
      );
      expect(Order.fromJson(orderJson(status: 'draft')).canApprove, isFalse);
    });

    test('price changes are reported, not hidden (BR-23)', () {
      final o = Order.fromJson(orderJson(lines: [line(price: 38000)]));
      expect(o.priceChanges.single.priceChanged, isTrue);
      expect(o.canApprove, isTrue, reason: 'the seller chooses a price');
    });

    test('status groups', () {
      expect(OrderStatus.parse('delivery_failed'), OrderStatus.deliveryFailed);
      expect(OrderStatus.values.where((s) => s.isTerminal), [
        OrderStatus.rejected,
        OrderStatus.returned,
        OrderStatus.cancelled,
      ]);
      expect(OrderStatus.values.where((s) => s.beforeDispatch), [
        OrderStatus.approved,
        OrderStatus.processing,
      ]);
      expect(OrderStatus.draft.canConfirm, isFalse);
      expect(OrderStatus.delivered.trackerStep, 3);
      expect(OrderStatus.cancelled.trackerStep, isNull);
    });

    test('order error codes and details', () {
      try {
        unwrapEnvelope({
          'ok': false,
          'error': {
            'code': 'INSUFFICIENT_STOCK',
            'details': {
              'lines': [
                {'item_id': 'l1', 'requested': 6, 'available': 5},
              ],
            },
          },
        });
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.code, ApiErrorCode.insufficientStock);
        expect(e.detailList('lines').single['available'], 5);
      }
      for (final (wire, code) in [
        ('INVALID_TRANSITION', ApiErrorCode.invalidTransition),
        ('INCOMPLETE_ORDER', ApiErrorCode.incompleteOrder),
        ('PRICE_CHANGED', ApiErrorCode.priceChanged),
        ('LINE_UNAVAILABLE', ApiErrorCode.lineUnavailable),
        ('EMAIL_NOT_VERIFIED', ApiErrorCode.emailNotVerified),
      ]) {
        expect(
          () => unwrapEnvelope({
            'ok': false,
            'error': {
              'code': wire,
              'details': {'current_status': 'approved'},
            },
          }),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.currentStatus, 'status', 'approved'),
          ),
        );
      }
    });
  });

  group('Order draft', () {
    const abaya = DraftLine(
      variantId: 'v1',
      name: 'Beige Abaya',
      label: 'M',
      unitPrice: 35000,
      quantity: 1,
      stockOnHand: 4,
    );

    test('sends documented fields only: never status, prices or totals', () {
      final json = const OrderDraft(
        customerName: ' Nzar ',
        customerPhone: '٠٧٥٠ ١١١ ٢٢٣٣',
        zoneId: 'z1',
        area: 'Ankawa',
        paymentMethod: PaymentMethod.cod,
        paymentNote: 'ignored for cash',
        lines: [abaya],
      ).toJson();
      expect(json, {
        'customer_name': 'Nzar',
        'customer_phone': '+9647501112233',
        'zone_id': 'z1',
        'area': 'Ankawa',
        'payment_method': 'cod',
        'discount': 0,
        'lines': [
          {'variant_id': 'v1', 'quantity': 1},
        ],
      });
      for (final k in [
        'status',
        'total',
        'subtotal',
        'approved_by',
        'unit_price',
      ]) {
        expect(json.containsKey(k), isFalse);
      }
    });

    test('lines merge per variant and stay within 1–999', () {
      var d = const OrderDraft()
          .addLine(abaya)
          .addLine(abaya.withQuantity(998));
      expect(d.lines.single.quantity, 999);
      d = d.setQuantity('v1', 3);
      expect(d.subtotal, 105000);
      expect(d.totalFor(5000), 105000, reason: 'no zone: no zone fee');
      expect(d.copyWith(zoneId: () => 'z1').totalFor(5000), 110000);
      expect(d.removeLine('v1').lines, isEmpty);
      expect(
        const OrderDraft(lines: [abaya]).setQuantity('v1', 0).fieldErrors,
        {'lines.0.quantity': 'out_of_range'},
      );
    });

    test('client checks mirror the server rules', () {
      expect(const OrderDraft(customerPhone: '12345').fieldErrors, {
        'customer_phone': 'invalid',
      });
      expect(const OrderDraft(lines: [abaya], discount: 40000).fieldErrors, {
        'discount': 'exceeds_subtotal',
      });
      expect(const OrderDraft().missing, [
        'customer_name',
        'customer_phone',
        'zone',
        'area',
        'delivery_fee',
        'payment_method',
        'lines',
      ]);
      expect(
        const OrderDraft(cityText: 'Koya', deliveryFee: 7000).missing,
        isNot(contains('delivery_fee')),
      );
    });

    test('an approved line keeps the units it holds available to itself', () {
      const held = DraftLine(
        variantId: 'v1',
        name: 'Beige Abaya',
        label: 'M',
        unitPrice: 35000,
        quantity: 2,
        stockOnHand: 1,
        held: 2,
      );
      expect(held.maxAvailable, 3);
      expect(
        const DraftLine(
          variantId: 'w',
          name: 'Wrap',
          label: '',
          unitPrice: 1,
          quantity: 1,
          trackStock: false,
        ).maxAvailable,
        isNull,
      );
    });

    test('the same draft keeps the same canonical form (one key)', () {
      expect(
        const OrderDraft(lines: [abaya]).canonical,
        const OrderDraft(lines: [abaya]).canonical,
      );
      expect(
        const OrderDraft(lines: [abaya]),
        isNot(const OrderDraft(lines: [abaya], discount: 1)),
      );
    });
  });
}
