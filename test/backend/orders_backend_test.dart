// Phase 7 end-to-end tests against the LOCAL Supabase stack: the app's own
// orders repository, real JWTs, PostgREST and Postgres. Run like
// backend_integration_test.dart (tag `backend`).
@Tags(['backend'])
library;

import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/features/catalog/domain/catalog.dart';
import 'package:aisellia/features/catalog/domain/product_draft.dart';
import 'package:aisellia/features/orders/data/orders_repository.dart';
import 'package:aisellia/features/orders/domain/order.dart';
import 'package:aisellia/features/orders/domain/order_draft.dart';
import 'package:aisellia/features/store/data/store_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_support.dart';
import 'catalog_backend_test.dart'
    show Seller, newIdempotencyKeyForTest, newSeller;

class OrderSeller {
  OrderSeller(this.seller, this.zoneId);
  final Seller seller;
  final String zoneId;
  String get storeId => seller.storeId;
  OrdersRepository get orders => SupabaseOrdersRepository(seller.client);
}

Future<OrderSeller> newOrderSeller(String who) async {
  final s = await newSeller(who);
  final zone = await SupabaseStoreRepository(s.client).upsertZone(
    s.storeId,
    name: 'Erbil',
    fee: 5000,
    idempotencyKey: newIdempotencyKeyForTest(),
  );
  return OrderSeller(s, zone.id);
}

/// A tracked product with one variant and [stock] units; returns its variant.
Future<Variant> stockedVariant(OrderSeller s, {required int stock}) async {
  final (p, _) = await s.seller.catalog.upsertProduct(
    s.storeId,
    newIdempotencyKeyForTest(),
    expectedVersion: null,
    draft: ProductDraft(
      name: 'Beige Abaya',
      basePrice: 35000,
      variants: [VariantDraft(optionValues: const [], initialStock: stock)],
    ),
    idempotencyKey: newIdempotencyKeyForTest(),
  );
  return p.variants.single;
}

OrderDraft completeDraft(OrderSeller s, Variant v, {int quantity = 1}) =>
    OrderDraft(
      customerName: 'Nzar Ahmad',
      customerPhone: '0750 111 2233',
      zoneId: s.zoneId,
      area: 'Ankawa',
      paymentMethod: PaymentMethod.cod,
      lines: [
        DraftLine(
          variantId: v.id,
          name: 'Beige Abaya',
          label: '',
          unitPrice: 1, // display only: the server prices the line
          quantity: quantity,
        ),
      ],
    );

Future<int> stockOf(
  OrderSeller s,
  String productVariantId,
  String productId,
) async => (await s.seller.catalog.getProduct(
  s.storeId,
  productId,
)).variants.firstWhere((v) => v.id == productVariantId).stockOnHand;

Future<Object> attempt(Future<Object> call) =>
    call.then<Object>((r) => r).catchError((Object e) => e);

void main() {
  group('Orders through PostgREST', skip: backendSkip, () {
    test('create, approve once, fulfil, collect cash', () async {
      final a = await newOrderSeller('ord-a');
      final v = await stockedVariant(a, stock: 4);
      final created = await a.orders.createOrder(
        a.storeId,
        completeDraft(a, v, quantity: 2),
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      expect(created.status, OrderStatus.pendingApproval);
      expect(created.customerPhone, '+9647501112233');
      expect(created.lines.single.unitPrice, 35000);
      expect(created.total, 75000, reason: 'server-computed, not the app');

      final key = newIdempotencyKeyForTest();
      final (approved, stock) = await a.orders.approve(
        a.storeId,
        created.id,
        expectedVersion: created.version,
        idempotencyKey: key,
      );
      expect(approved.status, OrderStatus.approved);
      expect(approved.approvedBy, Actor.you);
      expect((stock.single.before, stock.single.after), (4, 2));

      // A lost answer replayed with the same key: the same result, no new
      // movement. A second device (new key): already approved.
      final (replayed, _) = await a.orders.approve(
        a.storeId,
        created.id,
        expectedVersion: created.version,
        idempotencyKey: key,
      );
      expect(replayed.version, approved.version);
      final again = await attempt(
        a.orders.approve(
          a.storeId,
          created.id,
          expectedVersion: created.version,
          idempotencyKey: newIdempotencyKeyForTest(),
        ),
      );
      expect(again, isA<ApiException>());
      expect((again as ApiException).code, ApiErrorCode.invalidTransition);
      expect(again.currentStatus, 'approved');

      final productId = approved.lines.single.productId!;
      expect(await stockOf(a, v.id, productId), 2);
      final (moves, _) = await a.seller.catalog.listMovements(
        a.storeId,
        productId,
      );
      expect(
        moves
            .where((m) => m.reason == StockReason.orderApproved)
            .map((m) => (m.delta, m.orderNumber)),
        [(-2, approved.number)],
      );

      var o = approved;
      for (final to in [OrderStatus.processing, OrderStatus.dispatched]) {
        o = await a.orders.transition(
          a.storeId,
          o.id,
          expectedVersion: o.version,
          to: to,
          idempotencyKey: newIdempotencyKeyForTest(),
        );
      }
      o = await a.orders.transition(
        a.storeId,
        o.id,
        expectedVersion: o.version,
        to: OrderStatus.delivered,
        payload: {'cod_collected': 50000},
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      expect((o.status, o.codOutstanding), (OrderStatus.delivered, 25000));
      o = await a.orders.recordCash(
        a.storeId,
        o.id,
        amount: 25000,
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      expect(o.codOutstanding, 0);

      final history = await a.orders.history(a.storeId, o.id);
      expect(
        history.where((h) => h.kind == HistoryKind.status).map((h) => h.to),
        [
          OrderStatus.pendingApproval,
          OrderStatus.approved,
          OrderStatus.processing,
          OrderStatus.dispatched,
          OrderStatus.delivered,
        ],
      );
      final counts = await a.orders.counts(a.storeId);
      expect(counts[OrderFilter.delivered], 1);
      final page = await a.orders.listOrders(
        a.storeId,
        const OrderQuery(text: '0750 111 2233'),
      );
      expect(page.items.single.number, o.number);
    });

    test('6 orders compete for 3 units: exactly 3 approvals succeed', () async {
      final a = await newOrderSeller('ord-race');
      final v = await stockedVariant(a, stock: 3);
      final orders = [
        for (var i = 0; i < 6; i++)
          await a.orders.createOrder(
            a.storeId,
            completeDraft(a, v),
            idempotencyKey: newIdempotencyKeyForTest(),
          ),
      ];
      final outcomes = await Future.wait([
        for (final o in orders)
          attempt(
            a.orders.approve(
              a.storeId,
              o.id,
              expectedVersion: o.version,
              idempotencyKey: newIdempotencyKeyForTest(),
            ),
          ),
      ]);
      expect(outcomes.whereType<(Order, List<StockChange>)>(), hasLength(3));
      expect(outcomes.whereType<ApiException>().map((e) => e.code).toSet(), {
        ApiErrorCode.insufficientStock,
      });
      final productId = orders.first.lines.single.productId!;
      expect(await stockOf(a, v.id, productId), 0, reason: 'never negative');
      final counts = await a.orders.counts(a.storeId);
      expect(counts[OrderFilter.active], 3);
      expect(counts[OrderFilter.needsApproval], 3);
    });

    test('one order approved from 8 devices at once: one approval', () async {
      final a = await newOrderSeller('ord-double');
      final v = await stockedVariant(a, stock: 5);
      final o = await a.orders.createOrder(
        a.storeId,
        completeDraft(a, v, quantity: 2),
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      final outcomes = await Future.wait([
        for (var i = 0; i < 8; i++)
          attempt(
            a.orders.approve(
              a.storeId,
              o.id,
              expectedVersion: o.version,
              idempotencyKey: newIdempotencyKeyForTest(),
            ),
          ),
      ]);
      expect(outcomes.whereType<(Order, List<StockChange>)>(), hasLength(1));
      expect(outcomes.whereType<ApiException>().map((e) => e.code).toSet(), {
        ApiErrorCode.invalidTransition,
      });
      final productId = o.lines.single.productId!;
      expect(await stockOf(a, v.id, productId), 3, reason: 'deducted once');

      // Cancelling from several devices restocks once.
      final approved = await a.orders.getOrder(a.storeId, o.id);
      final cancels = await Future.wait([
        for (var i = 0; i < 5; i++)
          attempt(
            a.orders.cancel(
              a.storeId,
              o.id,
              expectedVersion: approved.version,
              reason: 'customer_cancelled',
              idempotencyKey: newIdempotencyKeyForTest(),
            ),
          ),
      ]);
      expect(cancels.whereType<(Order, List<StockChange>)>(), hasLength(1));
      expect(await stockOf(a, v.id, productId), 5, reason: 'restocked once');
    });

    test('values the app must not decide are refused', () async {
      final a = await newOrderSeller('ord-trust');
      final v = await stockedVariant(a, stock: 2);
      final raw = await attempt(
        callApi(
          a.seller.client,
          'create_order',
          params: {
            'p_store_id': a.storeId,
            'p_order': {
              ...completeDraft(a, v).toJson(),
              'status': 'approved',
              'total': 1,
              'approved_by': a.seller.client.auth.currentUser!.id,
            },
            'p_idempotency_key': newIdempotencyKeyForTest(),
          },
        ),
      );
      expect((raw as ApiException).code, ApiErrorCode.validationFailed);
      expect(raw.fields, {
        'status': 'unknown',
        'total': 'unknown',
        'approved_by': 'unknown',
      });
      final counts = await a.orders.counts(a.storeId);
      expect(counts[OrderFilter.all], 0);
    });

    test('seller B cannot see or change seller A\'s orders', () async {
      final a = await newOrderSeller('ord-iso-a');
      final b = await newOrderSeller('ord-iso-b');
      final v = await stockedVariant(a, stock: 3);
      final o = await a.orders.createOrder(
        a.storeId,
        completeDraft(a, v),
        idempotencyKey: newIdempotencyKeyForTest(),
      );
      for (final storeId in [a.storeId, b.storeId]) {
        for (final call in <Future<Object> Function()>[
          () => b.orders.getOrder(storeId, o.id),
          () => b.orders.history(storeId, o.id),
          () => b.orders.approve(
            storeId,
            o.id,
            expectedVersion: o.version,
            idempotencyKey: newIdempotencyKeyForTest(),
          ),
          () => b.orders.reject(
            storeId,
            o.id,
            expectedVersion: o.version,
            reason: 'duplicate',
            idempotencyKey: newIdempotencyKeyForTest(),
          ),
          () => b.orders.updateDraft(
            storeId,
            o.id,
            expectedVersion: o.version,
            draft: const OrderDraft(),
            idempotencyKey: newIdempotencyKeyForTest(),
          ),
        ]) {
          final r = await attempt(call());
          expect((r as ApiException).code, ApiErrorCode.notFound);
        }
      }
      final listA = await attempt(
        b.orders.listOrders(a.storeId, const OrderQuery()),
      );
      expect((listA as ApiException).code, ApiErrorCode.notFound);
      final borrow = await attempt(
        b.orders.createOrder(
          b.storeId,
          completeDraft(b, v),
          idempotencyKey: newIdempotencyKeyForTest(),
        ),
      );
      expect((borrow as ApiException).fields['lines.0.variant_id'], 'unknown');

      final after = await a.orders.getOrder(a.storeId, o.id);
      expect((after.status, after.version), (o.status, o.version));
    });
  });
}
