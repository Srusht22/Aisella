import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../catalog/application/catalog_providers.dart'
    show currentStoreIdProvider;
import '../../orders/application/order_providers.dart'
    show orderCountsProvider, orderListProvider, orderProvider;
import '../../orders/domain/order.dart';
import '../../store/application/workspace_controller.dart'
    show noAutomaticRetry;
import '../data/fulfilment_repository.dart';
import '../domain/fulfilment.dart';

export '../data/fulfilment_repository.dart' show fulfilmentRepositoryProvider;

String _requireStore(Ref ref) {
  final id = ref.read(currentStoreIdProvider);
  if (id == null) throw const ApiException(ApiErrorCode.notFound);
  return id;
}

/// Active couriers (for pickers) or all (for the couriers screen).
final couriersProvider = FutureProvider.autoDispose.family<List<Courier>, bool>(
  (ref, includeInactive) {
    final storeId = ref.watch(currentStoreIdProvider);
    if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
    return ref
        .read(fulfilmentRepositoryProvider)
        .couriers(storeId, includeInactive: includeInactive);
  },
  retry: noAutomaticRetry,
);

final deliveryListsProvider = FutureProvider.autoDispose<DeliveryListsPage>((
  ref,
) {
  final storeId = ref.watch(currentStoreIdProvider);
  if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
  return ref.read(fulfilmentRepositoryProvider).deliveryLists(storeId);
}, retry: noAutomaticRetry);

final deliveryListProvider = FutureProvider.autoDispose
    .family<DeliveryList, String>((ref, listId) {
      final storeId = ref.watch(currentStoreIdProvider);
      if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
      return ref
          .read(fulfilmentRepositoryProvider)
          .deliveryList(storeId, listId);
    }, retry: noAutomaticRetry);

final fulfilmentActionsProvider = Provider<FulfilmentActions>(
  FulfilmentActions.new,
);

/// Writes refresh what they change. A retry after a lost answer reuses the
/// same idempotency key, so it is applied once.
class FulfilmentActions {
  FulfilmentActions(this._ref);

  final Ref _ref;

  FulfilmentRepository get _repo => _ref.read(fulfilmentRepositoryProvider);

  Future<T> _withReplay<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException catch (e) {
      if (!e.outcomeUnknown) rethrow;
      return run();
    }
  }

  void _refreshOrders([Iterable<String> orderIds = const []]) {
    _ref.invalidate(orderListProvider);
    _ref.invalidate(orderCountsProvider);
    for (final id in orderIds) {
      _ref.invalidate(orderProvider(id));
    }
  }

  void _refreshCouriers() {
    _ref.invalidate(couriersProvider(true));
    _ref.invalidate(couriersProvider(false));
  }

  Future<Courier> saveCourier({
    Courier? existing,
    required String name,
    String? phone,
    bool active = true,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final c = await _withReplay(
      () => _repo.saveCourier(
        storeId,
        courierId: existing?.id,
        expectedVersion: existing?.version,
        name: name,
        phone: phone,
        active: active,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refreshCouriers();
    return c;
  }

  Future<DeliveryList> createList({
    String? courierId,
    required List<String> orderIds,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final l = await _withReplay(
      () => _repo.createDeliveryList(
        storeId,
        courierId: courierId,
        orderIds: orderIds,
        idempotencyKey: idempotencyKey,
      ),
    );
    _ref.invalidate(deliveryListsProvider);
    _refreshOrders(orderIds);
    return l;
  }

  Future<DeliveryList> updateList(
    DeliveryList list, {
    required String action,
    String? courierId,
    List<String>? orderIds,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    try {
      return await _withReplay(
        () => _repo.updateDeliveryList(
          storeId,
          list,
          action: action,
          courierId: courierId,
          orderIds: orderIds,
          idempotencyKey: idempotencyKey,
        ),
      );
    } finally {
      _ref.invalidate(deliveryListsProvider);
      _ref.invalidate(deliveryListProvider(list.id));
      _refreshOrders([...list.stops.map((s) => s.orderId), ...?orderIds]);
      if (action == 'hand_over') _refreshCouriers();
    }
  }

  Future<Order> recordPayment(
    Order order, {
    required PaymentChannel method,
    required int amount,
    String? reference,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final o = await _withReplay(
      () => _repo.recordPayment(
        storeId,
        order.id,
        method: method,
        amount: amount,
        reference: reference,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refreshOrders([order.id]);
    return o;
  }

  Future<Settlement> settle(
    Courier courier, {
    required int amount,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final s = await _withReplay(
      () => _repo.settleCourier(
        storeId,
        courier.id,
        amount: amount,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refreshCouriers();
    _refreshOrders();
    return s;
  }
}
