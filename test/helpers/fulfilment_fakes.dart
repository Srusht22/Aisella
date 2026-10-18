import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/features/fulfilment/data/fulfilment_repository.dart';
import 'package:aisellia/features/fulfilment/domain/fulfilment.dart';
import 'package:aisellia/features/orders/domain/order.dart';

import 'order_fakes.dart';

/// In-memory couriers, delivery lists, payments and settlements with the
/// server rules the screens rely on (Phase 10): ready statuses, one open list
/// per order, hand-over all or nothing, payments never above the total,
/// settlements never above what is owed. Records every call.
class FakeFulfilmentRepository implements FulfilmentRepository {
  FakeFulfilmentRepository({this.orders, List<Courier>? couriers})
    : _couriers = [...?couriers];

  final FakeOrdersRepository? orders;
  final List<Courier> _couriers;
  final _lists = <String, Map<String, dynamic>>{};
  final calls = <String>[];
  var _seq = 0;

  /// The next call fails with this error (then it is cleared).
  ApiException? failNext;

  void _maybeFail(String call) {
    calls.add(call);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  static const _ready = {'approved', 'processing', 'delivery_failed'};

  Iterable<String> get _orderIds => orders?.ids ?? const [];

  String? _openListOf(String orderId) => _lists.entries
      .where(
        (e) =>
            e.value['status'] == 'open' &&
            (e.value['orders'] as List).contains(orderId),
      )
      .map((e) => e.key)
      .firstOrNull;

  Courier? _courier(String? id) =>
      _couriers.where((c) => c.id == id).firstOrNull;

  DeliveryList _list(String id) {
    final l = _lists[id]!;
    final c = _courier(l['courier_id'] as String?);
    final stops = [
      for (final oid in l['orders'] as List)
        () {
          final o = orders!.raw(oid as String);
          return {
            'order_id': oid,
            'number': o['number'],
            'status': o['status'],
            'customer_name': o['customer_name'],
            'phone': o['customer_phone'],
            'zone': 'Erbil',
            'area': o['area'],
            'payment_method': o['payment_method'],
            'currency': 'IQD',
            'total': 50000,
            'cash_to_collect': o['payment_method'] == 'cod' ? 50000 : 0,
            'issues': <Object>[],
            'items': [
              {'name': 'Beige Abaya', 'variant': 'M', 'quantity': 1},
            ],
          };
        }(),
    ];
    return DeliveryList.fromJson({
      'id': id,
      'number': l['number'],
      'status': l['status'],
      'version': l['version'],
      'courier': c == null ? null : {'id': c.id, 'name': c.name},
      'order_count': stops.length,
      'cod_total': stops.fold<int>(
        0,
        (s, x) => s + (x['cash_to_collect'] as int),
      ),
      'created_at': '2026-10-15T09:00:00Z',
      'stops': stops,
    });
  }

  @override
  Future<List<Courier>> couriers(
    String storeId, {
    bool includeInactive = false,
  }) async {
    _maybeFail('couriers');
    return [
      for (final c in _couriers)
        if (includeInactive || c.active) c,
    ];
  }

  @override
  Future<Courier> saveCourier(
    String storeId, {
    String? courierId,
    int? expectedVersion,
    required String name,
    String? phone,
    bool active = true,
    required String idempotencyKey,
  }) async {
    _maybeFail('saveCourier:$name:${phone ?? '-'}:$active');
    if (_couriers.any(
      (c) =>
          c.id != courierId &&
          c.active &&
          c.name.toLowerCase() == name.toLowerCase(),
    )) {
      throw const ApiException(
        ApiErrorCode.validationFailed,
        fields: {'name': 'duplicate'},
      );
    }
    final old = _courier(courierId);
    final c = Courier(
      id: courierId ?? 'courier-${++_seq}',
      name: name,
      phone: phone,
      active: active,
      version: (old?.version ?? 0) + 1,
      owed: old?.owed ?? 0,
      owedOrders: old?.owedOrders ?? 0,
    );
    _couriers
      ..removeWhere((x) => x.id == c.id)
      ..add(c);
    return c;
  }

  @override
  Future<DeliveryListsPage> deliveryLists(String storeId) async {
    _maybeFail('lists');
    return DeliveryListsPage(
      lists: [for (final id in _lists.keys.toList().reversed) _list(id)],
      ready: [
        for (final id in _orderIds)
          if (_ready.contains(orders!.raw(id)['status']) &&
              _openListOf(id) == null)
            ReadyOrder.fromJson({
              'order_id': id,
              'number': orders!.raw(id)['number'],
              'customer_name': orders!.raw(id)['customer_name'],
              'zone': 'Erbil',
              'total': 50000,
              'currency': 'IQD',
              'complete': true,
            }),
      ],
    );
  }

  @override
  Future<DeliveryList> deliveryList(String storeId, String listId) async {
    _maybeFail('list:$listId');
    if (!_lists.containsKey(listId)) {
      throw const ApiException(ApiErrorCode.notFound);
    }
    return _list(listId);
  }

  void _checkOrders(List<String> ids, String? listId) {
    for (final id in ids) {
      if (!_ready.contains(orders!.raw(id)['status'])) {
        throw const ApiException(ApiErrorCode.invalidTransition);
      }
      final other = _openListOf(id);
      if (other != null && other != listId) {
        throw const ApiException(
          ApiErrorCode.validationFailed,
          fields: {'order_ids': 'on_another_list'},
        );
      }
    }
  }

  @override
  Future<DeliveryList> createDeliveryList(
    String storeId, {
    String? courierId,
    required List<String> orderIds,
    required String idempotencyKey,
  }) async {
    _maybeFail('createList:${courierId ?? '-'}:${orderIds.join(',')}');
    _checkOrders(orderIds, null);
    final id = 'list-${++_seq}';
    _lists[id] = {
      'number': _lists.length + 1,
      'status': 'open',
      'version': 1,
      'courier_id': courierId,
      'orders': [...orderIds],
    };
    return _list(id);
  }

  @override
  Future<DeliveryList> updateDeliveryList(
    String storeId,
    DeliveryList list, {
    required String action,
    String? courierId,
    List<String>? orderIds,
    required String idempotencyKey,
  }) async {
    _maybeFail('updateList:$action:${courierId ?? '-'}');
    final l = _lists[list.id]!;
    if (l['status'] != 'open') {
      throw const ApiException(ApiErrorCode.invalidTransition);
    }
    if (l['version'] != list.version) {
      throw const ApiException(ApiErrorCode.conflictVersion);
    }
    switch (action) {
      case 'set_orders':
        _checkOrders(orderIds!, list.id);
        l['orders'] = [...orderIds];
        l['courier_id'] = courierId;
      case 'cancel':
        l['status'] = 'cancelled';
      case 'hand_over':
        if (l['courier_id'] == null) {
          throw const ApiException(
            ApiErrorCode.validationFailed,
            fields: {'courier_id': 'required'},
          );
        }
        final blocked = [
          for (final id in l['orders'] as List)
            if (!_ready.contains(orders!.raw(id as String)['status']))
              {'order_number': orders!.raw(id)['number']},
        ];
        if (blocked.isNotEmpty) {
          throw ApiException(
            ApiErrorCode.incompleteOrder,
            details: {'orders': blocked},
          );
        }
        final c = _courier(l['courier_id'] as String?)!;
        for (final id in l['orders'] as List) {
          orders!.raw(id as String)['status'] = 'dispatched';
          orders!.overlays[id] = {
            ...?orders!.overlays[id],
            'courier': {'id': c.id, 'name': c.name},
          };
        }
        l['status'] = 'handed_over';
    }
    l['version'] = (l['version'] as int) + 1;
    return _list(list.id);
  }

  @override
  Future<Order> recordPayment(
    String storeId,
    String orderId, {
    required PaymentChannel method,
    required int amount,
    String? reference,
    required String idempotencyKey,
  }) async {
    _maybeFail('payment:$orderId:${method.wire}:$amount:${reference ?? '-'}');
    final current = await orders!.getOrder(storeId, orderId);
    if (current.paidTotal + amount > current.total) {
      throw const ApiException(
        ApiErrorCode.validationFailed,
        fields: {'amount': 'exceeds_due'},
      );
    }
    final overlay = {...?orders!.overlays[orderId]};
    overlay['paid_total'] = current.paidTotal + amount;
    overlay['payments'] = [
      ...?overlay['payments'] as List?,
      {
        'method': method.wire,
        'amount': amount,
        'reference': reference,
        'recorded_at': '2026-10-15T09:00:00Z',
      },
    ];
    orders!.overlays[orderId] = overlay;
    return orders!.getOrder(storeId, orderId);
  }

  @override
  Future<Settlement> settleCourier(
    String storeId,
    String courierId, {
    required int amount,
    required String idempotencyKey,
  }) async {
    _maybeFail('settle:$courierId:$amount');
    final c = _courier(courierId)!;
    if (amount > c.owed) {
      throw const ApiException(
        ApiErrorCode.validationFailed,
        fields: {'amount': 'exceeds_due'},
      );
    }
    final updated = Courier(
      id: c.id,
      name: c.name,
      phone: c.phone,
      active: c.active,
      version: c.version,
      owed: c.owed - amount,
      owedOrders: c.owed - amount == 0 ? 0 : c.owedOrders,
    );
    _couriers[_couriers.indexOf(c)] = updated;
    return Settlement(
      allocations: [
        for (var i = 0; i < (amount == c.owed ? c.owedOrders : 1); i++)
          (number: 1000 + i, amount: amount),
      ],
      courier: updated,
    );
  }
}
