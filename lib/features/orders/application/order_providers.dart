import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../catalog/application/catalog_providers.dart';
import '../../catalog/domain/catalog.dart';
import '../../store/application/workspace_controller.dart'
    show noAutomaticRetry;
import '../data/orders_repository.dart';
import '../domain/order.dart';
import '../domain/order_draft.dart';

export '../data/orders_repository.dart' show ordersRepositoryProvider;

String _requireStore(Ref ref) {
  final id = ref.read(currentStoreIdProvider);
  if (id == null) throw const ApiException(ApiErrorCode.notFound);
  return id;
}

// ---------------------------------------------------------------------------
// Order list (OR-01): filter, debounced search, pages.
// ---------------------------------------------------------------------------

const orderPageSize = 30;

final orderQueryProvider = NotifierProvider<OrderQueryController, OrderQuery>(
  OrderQueryController.new,
);

class OrderQueryController extends Notifier<OrderQuery> {
  Timer? _debounce;

  @override
  OrderQuery build() {
    ref.watch(currentStoreIdProvider);
    ref.onDispose(() => _debounce?.cancel());
    return const OrderQuery();
  }

  void setText(String text) {
    _debounce?.cancel();
    _debounce = Timer(searchDebounce, () {
      if (text.trim() != state.text.trim()) {
        state = state.copyWith(text: text.trim());
      }
    });
  }

  void setFilter(OrderFilter filter) => state = state.copyWith(filter: filter);

  void clear() {
    _debounce?.cancel();
    state = const OrderQuery();
  }
}

@immutable
class OrderListState {
  const OrderListState({
    required this.query,
    required this.items,
    required this.total,
    required this.hasMore,
    this.loadingMore = false,
    this.moreFailed = false,
  });

  final OrderQuery query;
  final List<OrderSummary> items;
  final int total;
  final bool hasMore;
  final bool loadingMore;
  final bool moreFailed;

  OrderListState copyWith({
    List<OrderSummary>? items,
    bool? hasMore,
    bool? loadingMore,
    bool? moreFailed,
  }) => OrderListState(
    query: query,
    items: items ?? this.items,
    total: total,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    moreFailed: moreFailed ?? this.moreFailed,
  );
}

final orderListProvider =
    AsyncNotifierProvider<OrderListController, OrderListState>(
      OrderListController.new,
      retry: noAutomaticRetry,
    );

class OrderListController extends AsyncNotifier<OrderListState> {
  int _generation = 0;

  @override
  Future<OrderListState> build() async {
    final storeId = ref.watch(currentStoreIdProvider);
    final query = ref.watch(orderQueryProvider);
    _generation++;
    if (storeId == null) {
      return OrderListState(
        query: query,
        items: const [],
        total: 0,
        hasMore: false,
      );
    }
    final page = await ref
        .read(ordersRepositoryProvider)
        .listOrders(storeId, query, limit: orderPageSize);
    return OrderListState(
      query: query,
      items: page.items,
      total: page.total,
      hasMore: page.hasMore,
    );
  }

  Future<void> loadMore() async {
    final current = state.value;
    final storeId = ref.read(currentStoreIdProvider);
    if (current == null ||
        storeId == null ||
        !current.hasMore ||
        current.loadingMore ||
        state.isLoading) {
      return;
    }
    final generation = _generation;
    state = AsyncData(current.copyWith(loadingMore: true, moreFailed: false));
    try {
      final page = await ref
          .read(ordersRepositoryProvider)
          .listOrders(
            storeId,
            current.query,
            offset: current.items.length,
            limit: orderPageSize,
          );
      if (generation != _generation) return;
      final seen = {for (final o in current.items) o.id};
      state = AsyncData(
        current.copyWith(
          items: [
            ...current.items,
            for (final o in page.items)
              if (!seen.contains(o.id)) o,
          ],
          hasMore: page.hasMore,
          loadingMore: false,
        ),
      );
    } on ApiException {
      if (generation != _generation) return;
      state = AsyncData(current.copyWith(loadingMore: false, moreFailed: true));
    }
  }
}

/// Counts for the chips and Today; each equals its list's total (server).
final orderCountsProvider = FutureProvider<OrderCounts?>(
  retry: noAutomaticRetry,
  (ref) async {
    final storeId = ref.watch(currentStoreIdProvider);
    if (storeId == null) return null;
    return ref.read(ordersRepositoryProvider).counts(storeId);
  },
);

// ---------------------------------------------------------------------------
// Order detail (OR-02, OR-05) and history (OR-11).
// ---------------------------------------------------------------------------

final orderProvider = FutureProvider.autoDispose.family<Order, String>(
  retry: noAutomaticRetry,
  (ref, orderId) async {
    final storeId = ref.watch(currentStoreIdProvider);
    if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
    return ref.read(ordersRepositoryProvider).getOrder(storeId, orderId);
  },
);

final orderHistoryProvider = FutureProvider.autoDispose
    .family<List<HistoryEntry>, String>(retry: noAutomaticRetry, (
      ref,
      orderId,
    ) async {
      final storeId = ref.watch(currentStoreIdProvider);
      if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
      return ref.read(ordersRepositoryProvider).history(storeId, orderId);
    });

// ---------------------------------------------------------------------------
// Product picker (OR-07): active products only; archived and inactive ones
// are never offered for a new line.
// ---------------------------------------------------------------------------

final pickerProductsProvider = FutureProvider.autoDispose
    .family<List<ProductSummary>, String>(retry: noAutomaticRetry, (
      ref,
      text,
    ) async {
      final storeId = ref.watch(currentStoreIdProvider);
      if (storeId == null) return const [];
      final page = await ref
          .read(catalogRepositoryProvider)
          .listProducts(storeId, CatalogQuery(text: text), limit: 50);
      return [
        for (final p in page.items)
          if (p.status == ProductStatus.active) p,
      ];
    });

// ---------------------------------------------------------------------------
// Mutations. Reads refresh only after the server confirmed. Every
// stock-moving call carries an idempotency key; a lost answer (timeout) is
// replayed once with the same key, so it can never apply twice.
// ---------------------------------------------------------------------------

/// The result of an approval: the approved order and the stock it moved.
typedef ApprovalOutcome = ({
  Order order,
  List<StockChange> stock,

  /// The order was already approved (another device or an earlier attempt
  /// whose answer was lost). Nothing new happened (Phase 3 §6.2).
  bool alreadyApproved,
});

final orderActionsProvider = Provider<OrderActions>(OrderActions.new);

class OrderActions {
  OrderActions(this._ref);

  final Ref _ref;

  OrdersRepository get _repo => _ref.read(ordersRepositoryProvider);

  Future<T> _withReplay<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException catch (e) {
      if (!e.outcomeUnknown) rethrow;
      return run();
    }
  }

  void _refresh(String orderId, {bool stock = false}) {
    _ref.invalidate(orderListProvider);
    _ref.invalidate(orderCountsProvider);
    _ref.invalidate(orderProvider(orderId));
    _ref.invalidate(orderHistoryProvider(orderId));
    if (stock) {
      // Stock changed: product lists, counts and histories are stale.
      _ref.invalidate(catalogListProvider);
      _ref.invalidate(catalogSummaryProvider);
      _ref.invalidate(productProvider);
      _ref.invalidate(movementsProvider);
    }
  }

  Future<Order> create(
    OrderDraft draft, {
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final order = await _withReplay(
      () => _repo.createOrder(storeId, draft, idempotencyKey: idempotencyKey),
    );
    _refresh(order.id);
    return order;
  }

  Future<Order> updateDraft(
    Order order,
    OrderDraft draft, {
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final updated = await _withReplay(
      () => _repo.updateDraft(
        storeId,
        order.id,
        expectedVersion: order.version,
        draft: draft,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(order.id);
    return updated;
  }

  /// Approves [order] as the seller saw it. An "already approved" answer is
  /// reported as such (with the server's order), never as a new approval.
  Future<ApprovalOutcome> approve(
    Order order, {
    Map<String, String> priceChoices = const {},
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    try {
      final (approved, stock) = await _withReplay(
        () => _repo.approve(
          storeId,
          order.id,
          expectedVersion: order.version,
          priceChoices: priceChoices,
          idempotencyKey: idempotencyKey,
        ),
      );
      _refresh(order.id, stock: true);
      return (order: approved, stock: stock, alreadyApproved: false);
    } on ApiException catch (e) {
      if (e.code == ApiErrorCode.invalidTransition &&
          e.currentStatus != null &&
          OrderStatus.parse(e.currentStatus) != OrderStatus.pendingApproval &&
          OrderStatus.parse(e.currentStatus) != OrderStatus.draft &&
          OrderStatus.parse(e.currentStatus) != OrderStatus.rejected) {
        final current = await _repo.getOrder(storeId, order.id);
        _refresh(order.id, stock: true);
        return (order: current, stock: <StockChange>[], alreadyApproved: true);
      }
      rethrow;
    }
  }

  Future<Order> reject(
    Order order, {
    required String reason,
    String? note,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final updated = await _withReplay(
      () => _repo.reject(
        storeId,
        order.id,
        expectedVersion: order.version,
        reason: reason,
        note: note,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(order.id);
    return updated;
  }

  Future<(Order, List<StockChange>)> editApproved(
    Order order,
    OrderDraft draft, {
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final result = await _withReplay(
      () => _repo.editApproved(
        storeId,
        order.id,
        expectedVersion: order.version,
        draft: draft,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(order.id, stock: true);
    return result;
  }

  Future<(Order, List<StockChange>)> cancel(
    Order order, {
    required String reason,
    String? note,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final result = await _withReplay(
      () => _repo.cancel(
        storeId,
        order.id,
        expectedVersion: order.version,
        reason: reason,
        note: note,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(order.id, stock: true);
    return result;
  }

  Future<Order> transition(
    Order order,
    OrderStatus to, {
    Map<String, dynamic> payload = const {},
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final updated = await _withReplay(
      () => _repo.transition(
        storeId,
        order.id,
        expectedVersion: order.version,
        to: to,
        payload: payload,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(order.id);
    return updated;
  }

  Future<(Order, List<StockChange>)> recordReturn(
    Order order, {
    required Map<String, ReturnDecision> lines,
    String? note,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final result = await _withReplay(
      () => _repo.recordReturn(
        storeId,
        order.id,
        expectedVersion: order.version,
        lines: lines,
        note: note,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(order.id, stock: true);
    return result;
  }

  Future<Order> recordCash(
    Order order, {
    required int amount,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final updated = await _withReplay(
      () => _repo.recordCash(
        storeId,
        order.id,
        amount: amount,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(order.id);
    return updated;
  }

  /// The seller says they sent the confirmation themselves (BR-46).
  Future<Order> markConfirmationSent(Order order) async {
    final storeId = _requireStore(_ref);
    final updated = await _withReplay(
      () => _repo.markConfirmationSent(storeId, order.id),
    );
    _refresh(order.id);
    return updated;
  }

  Future<Order> updateNote(Order order, String note) async {
    final storeId = _requireStore(_ref);
    final updated = await _withReplay(
      () => _repo.updateNote(
        storeId,
        order.id,
        expectedVersion: order.version,
        note: note,
      ),
    );
    _refresh(order.id);
    return updated;
  }
}
