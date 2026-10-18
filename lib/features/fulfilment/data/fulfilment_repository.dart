import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/api.dart';
import '../../orders/domain/order.dart';
import '../domain/fulfilment.dart';

/// Couriers, delivery lists, recorded payments and courier settlement
/// (Phase 10, roadmap R8). Every call runs with the seller's session and is
/// authorized by the database; nothing here moves money.
abstract interface class FulfilmentRepository {
  Future<List<Courier>> couriers(String storeId, {bool includeInactive});

  /// Creates ([courierId] null) or updates a courier.
  Future<Courier> saveCourier(
    String storeId, {
    String? courierId,
    int? expectedVersion,
    required String name,
    String? phone,
    bool active,
    required String idempotencyKey,
  });

  Future<DeliveryListsPage> deliveryLists(String storeId);

  Future<DeliveryList> deliveryList(String storeId, String listId);

  Future<DeliveryList> createDeliveryList(
    String storeId, {
    String? courierId,
    required List<String> orderIds,
    required String idempotencyKey,
  });

  /// [action]: `set_orders`, `hand_over` or `cancel`.
  Future<DeliveryList> updateDeliveryList(
    String storeId,
    DeliveryList list, {
    required String action,
    String? courierId,
    List<String>? orderIds,
    required String idempotencyKey,
  });

  Future<Order> recordPayment(
    String storeId,
    String orderId, {
    required PaymentChannel method,
    required int amount,
    String? reference,
    required String idempotencyKey,
  });

  Future<Settlement> settleCourier(
    String storeId,
    String courierId, {
    required int amount,
    required String idempotencyKey,
  });
}

final fulfilmentRepositoryProvider = Provider<FulfilmentRepository>(
  (ref) => SupabaseFulfilmentRepository(ref.watch(supabaseClientProvider)),
);

class SupabaseFulfilmentRepository implements FulfilmentRepository {
  SupabaseFulfilmentRepository(this._client);

  final SupabaseClient _client;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> params) =>
      callApi(_client, fn, params: params);

  @override
  Future<List<Courier>> couriers(
    String storeId, {
    bool includeInactive = false,
  }) async => [
    for (final c
        in (await _call('list_couriers', {
                  'p_store_id': storeId,
                  'p_include_inactive': includeInactive,
                }))['items']
                as List? ??
            const [])
      Courier.fromJson((c as Map).cast<String, dynamic>()),
  ];

  @override
  Future<Courier> saveCourier(
    String storeId, {
    String? courierId,
    int? expectedVersion,
    required String name,
    String? phone,
    bool active = true,
    required String idempotencyKey,
  }) async => Courier.fromJson(
    await _call('upsert_courier', {
      'p_store_id': storeId,
      'p_courier_id': courierId,
      'p_expected_version': expectedVersion,
      'p_name': name,
      'p_phone': phone,
      'p_active': active,
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<DeliveryListsPage> deliveryLists(String storeId) async =>
      DeliveryListsPage.fromJson(
        await _call('list_delivery_lists', {
          'p_store_id': storeId,
          'p_status': null,
        }),
      );

  @override
  Future<DeliveryList> deliveryList(String storeId, String listId) async =>
      DeliveryList.fromJson(
        await _call('get_delivery_list', {
          'p_store_id': storeId,
          'p_list_id': listId,
        }),
      );

  @override
  Future<DeliveryList> createDeliveryList(
    String storeId, {
    String? courierId,
    required List<String> orderIds,
    required String idempotencyKey,
  }) async => DeliveryList.fromJson(
    await _call('create_delivery_list', {
      'p_store_id': storeId,
      'p_courier_id': courierId,
      'p_order_ids': orderIds,
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<DeliveryList> updateDeliveryList(
    String storeId,
    DeliveryList list, {
    required String action,
    String? courierId,
    List<String>? orderIds,
    required String idempotencyKey,
  }) async => DeliveryList.fromJson(
    await _call('update_delivery_list', {
      'p_store_id': storeId,
      'p_list_id': list.id,
      'p_expected_version': list.version,
      'p_action': action,
      'p_courier_id': courierId,
      'p_order_ids': orderIds,
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<Order> recordPayment(
    String storeId,
    String orderId, {
    required PaymentChannel method,
    required int amount,
    String? reference,
    required String idempotencyKey,
  }) async => Order.fromJson(
    await _call('record_payment', {
      'p_store_id': storeId,
      'p_order_id': orderId,
      'p_method': method.wire,
      'p_amount': amount,
      'p_reference': reference,
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<Settlement> settleCourier(
    String storeId,
    String courierId, {
    required int amount,
    required String idempotencyKey,
  }) async => Settlement.fromJson(
    await _call('settle_courier', {
      'p_store_id': storeId,
      'p_courier_id': courierId,
      'p_amount': amount,
      'p_idempotency_key': idempotencyKey,
    }),
  );
}
