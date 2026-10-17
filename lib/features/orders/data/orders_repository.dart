import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/api.dart';
import '../domain/order.dart';
import '../domain/order_draft.dart';

/// Order reads and writes (`api.*` functions; Phase 3 contracts §3.7). The
/// database authorises every call, computes status, prices and totals, and
/// is the only place an order can be approved.
abstract interface class OrdersRepository {
  Future<OrderPage> listOrders(
    String storeId,
    OrderQuery query, {
    int offset = 0,
    int limit = 30,
  });

  Future<OrderCounts> counts(String storeId);

  Future<Order> getOrder(String storeId, String orderId);

  Future<List<HistoryEntry>> history(String storeId, String orderId);

  /// A manual order: draft or pending approval, decided by the server.
  Future<Order> createOrder(
    String storeId,
    OrderDraft draft, {
    required String idempotencyKey,
  });

  Future<Order> updateDraft(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required OrderDraft draft,
    required String idempotencyKey,
  });

  /// [priceChoices]: `{itemId: 'quoted' | 'current'}` for changed prices.
  Future<(Order, List<StockChange>)> approve(
    String storeId,
    String orderId, {
    required int expectedVersion,
    Map<String, String> priceChoices = const {},
    required String idempotencyKey,
  });

  Future<Order> reject(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required String reason,
    String? note,
    required String idempotencyKey,
  });

  Future<(Order, List<StockChange>)> editApproved(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required OrderDraft draft,
    required String idempotencyKey,
  });

  Future<(Order, List<StockChange>)> cancel(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required String reason,
    String? note,
    required String idempotencyKey,
  });

  /// processing, dispatched, delivered or delivery_failed.
  Future<Order> transition(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required OrderStatus to,
    Map<String, dynamic> payload = const {},
    required String idempotencyKey,
  });

  Future<(Order, List<StockChange>)> recordReturn(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required Map<String, ReturnDecision> lines,
    String? note,
    required String idempotencyKey,
  });

  Future<Order> recordCash(
    String storeId,
    String orderId, {
    required int amount,
    required String idempotencyKey,
  });

  Future<Order> markConfirmationSent(String storeId, String orderId);

  Future<Order> updateNote(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required String note,
  });
}

class SupabaseOrdersRepository implements OrdersRepository {
  SupabaseOrdersRepository(this._client);

  final SupabaseClient _client;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> params) =>
      callApi(_client, fn, params: params);

  @override
  Future<OrderPage> listOrders(
    String storeId,
    OrderQuery query, {
    int offset = 0,
    int limit = 30,
  }) async => OrderPage.fromJson(
    await _call('list_orders', {
      'p_store_id': storeId,
      'p_query': query.text.trim().isEmpty ? null : query.text.trim(),
      'p_filter': query.filter.wire,
      'p_limit': limit,
      'p_offset': offset,
    }),
  );

  @override
  Future<OrderCounts> counts(String storeId) async => OrderCounts.fromJson(
    await _call('order_summary', {'p_store_id': storeId}),
  );

  @override
  Future<Order> getOrder(String storeId, String orderId) async =>
      Order.fromJson(
        await _call('get_order', {
          'p_store_id': storeId,
          'p_order_id': orderId,
        }),
      );

  @override
  Future<List<HistoryEntry>> history(String storeId, String orderId) async {
    final data = await _call('order_history', {
      'p_store_id': storeId,
      'p_order_id': orderId,
    });
    return [
      for (final e in data['items'] as List? ?? [])
        HistoryEntry.fromJson((e as Map).cast<String, dynamic>()),
    ];
  }

  @override
  Future<Order> createOrder(
    String storeId,
    OrderDraft draft, {
    required String idempotencyKey,
  }) async => Order.fromJson(
    await _call('create_order', {
      'p_store_id': storeId,
      'p_order': draft.toJson(),
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<Order> updateDraft(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required OrderDraft draft,
    required String idempotencyKey,
  }) async => Order.fromJson(
    await _call('update_draft', {
      'p_store_id': storeId,
      'p_order_id': orderId,
      'p_expected_version': expectedVersion,
      'p_order': draft.toJson(),
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<(Order, List<StockChange>)> approve(
    String storeId,
    String orderId, {
    required int expectedVersion,
    Map<String, String> priceChoices = const {},
    required String idempotencyKey,
  }) async {
    final data = await _call('approve_order', {
      'p_store_id': storeId,
      'p_order_id': orderId,
      'p_expected_version': expectedVersion,
      'p_price_choices': priceChoices,
      'p_idempotency_key': idempotencyKey,
    });
    return (Order.fromJson(data), stockChangesFrom(data['stock_after']));
  }

  @override
  Future<Order> reject(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required String reason,
    String? note,
    required String idempotencyKey,
  }) async => Order.fromJson(
    await _call('reject_draft', {
      'p_store_id': storeId,
      'p_order_id': orderId,
      'p_expected_version': expectedVersion,
      'p_reason': reason,
      'p_note': note,
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<(Order, List<StockChange>)> editApproved(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required OrderDraft draft,
    required String idempotencyKey,
  }) async {
    final data = await _call('edit_approved_order', {
      'p_store_id': storeId,
      'p_order_id': orderId,
      'p_expected_version': expectedVersion,
      'p_order': draft.toJson(),
      'p_idempotency_key': idempotencyKey,
    });
    return (Order.fromJson(data), stockChangesFrom(data['stock_diff']));
  }

  @override
  Future<(Order, List<StockChange>)> cancel(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required String reason,
    String? note,
    required String idempotencyKey,
  }) async {
    final data = await _call('cancel_order', {
      'p_store_id': storeId,
      'p_order_id': orderId,
      'p_expected_version': expectedVersion,
      'p_reason': reason,
      'p_note': note,
      'p_idempotency_key': idempotencyKey,
    });
    return (Order.fromJson(data), stockChangesFrom(data['restocked']));
  }

  @override
  Future<Order> transition(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required OrderStatus to,
    Map<String, dynamic> payload = const {},
    required String idempotencyKey,
  }) async => Order.fromJson(
    await _call('transition_order', {
      'p_store_id': storeId,
      'p_order_id': orderId,
      'p_expected_version': expectedVersion,
      'p_to': to.wire,
      'p_payload': payload,
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<(Order, List<StockChange>)> recordReturn(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required Map<String, ReturnDecision> lines,
    String? note,
    required String idempotencyKey,
  }) async {
    final data = await _call('record_return', {
      'p_store_id': storeId,
      'p_order_id': orderId,
      'p_expected_version': expectedVersion,
      'p_lines': [
        for (final e in lines.entries)
          {
            'item_id': e.key,
            'restock_qty': e.value.restock,
            'writeoff_qty': e.value.writeOff,
          },
      ],
      'p_note': note,
      'p_idempotency_key': idempotencyKey,
    });
    return (Order.fromJson(data), stockChangesFrom(data['restocked']));
  }

  @override
  Future<Order> recordCash(
    String storeId,
    String orderId, {
    required int amount,
    required String idempotencyKey,
  }) async => Order.fromJson(
    await _call('record_cod', {
      'p_store_id': storeId,
      'p_order_id': orderId,
      'p_amount': amount,
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<Order> markConfirmationSent(String storeId, String orderId) async =>
      Order.fromJson(
        await _call('mark_confirmation_sent', {
          'p_store_id': storeId,
          'p_order_id': orderId,
        }),
      );

  @override
  Future<Order> updateNote(
    String storeId,
    String orderId, {
    required int expectedVersion,
    required String note,
  }) async => Order.fromJson(
    await _call('update_order_note', {
      'p_store_id': storeId,
      'p_order_id': orderId,
      'p_expected_version': expectedVersion,
      'p_note': note,
    }),
  );
}

final ordersRepositoryProvider = Provider<OrdersRepository>(
  (ref) => SupabaseOrdersRepository(ref.watch(supabaseClientProvider)),
);
