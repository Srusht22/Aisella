import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../store/application/workspace_controller.dart';
import '../data/catalog_repository.dart';
import '../data/media_store.dart';
import '../domain/catalog.dart';
import '../domain/product_draft.dart';

export '../data/catalog_repository.dart' show catalogRepositoryProvider;
export '../data/media_store.dart'
    show
        MediaException,
        MediaFailure,
        PhotoSource,
        imagePreparerProvider,
        mediaStoreProvider,
        photoPickerProvider;

/// The signed-in seller's store id. Every catalog provider is keyed on it, so
/// signing out or switching seller discards the catalog state.
final currentStoreIdProvider = Provider<String?>(
  (ref) => ref.watch(workspaceProvider.select((w) => w.value?.store?.id)),
);

String _requireStore(Ref ref) {
  final id = ref.read(currentStoreIdProvider);
  if (id == null) throw const ApiException(ApiErrorCode.notFound);
  return id;
}

// ---------------------------------------------------------------------------
// Product list (PR-01): query, debounced search, pages.
// ---------------------------------------------------------------------------

const catalogPageSize = 30;
const searchDebounce = Duration(milliseconds: 300);

final catalogQueryProvider =
    NotifierProvider<CatalogQueryController, CatalogQuery>(
      CatalogQueryController.new,
    );

class CatalogQueryController extends Notifier<CatalogQuery> {
  Timer? _debounce;

  @override
  CatalogQuery build() {
    ref.watch(currentStoreIdProvider);
    ref.onDispose(() => _debounce?.cancel());
    return const CatalogQuery();
  }

  /// Search text is applied after a short pause in typing, so each keystroke
  /// does not start a request.
  void setText(String text) {
    _debounce?.cancel();
    _debounce = Timer(searchDebounce, () {
      if (text.trim() != state.text.trim()) {
        state = state.copyWith(text: text.trim());
      }
    });
  }

  void setFilter(CatalogFilter filter) =>
      state = state.copyWith(filter: filter);
  void setCategory(String? category) =>
      state = state.copyWith(category: () => category);
  void setSort(CatalogSort sort) => state = state.copyWith(sort: sort);

  void clear() {
    _debounce?.cancel();
    state = const CatalogQuery();
  }
}

@immutable
class CatalogListState {
  const CatalogListState({
    required this.query,
    required this.items,
    required this.total,
    required this.hasMore,
    this.loadingMore = false,
    this.moreFailed = false,
  });

  /// The query these items answer (the UI may already show a newer one).
  final CatalogQuery query;
  final List<ProductSummary> items;
  final int total;
  final bool hasMore;
  final bool loadingMore;
  final bool moreFailed;

  CatalogListState copyWith({
    List<ProductSummary>? items,
    bool? hasMore,
    bool? loadingMore,
    bool? moreFailed,
  }) => CatalogListState(
    query: query,
    items: items ?? this.items,
    total: total,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    moreFailed: moreFailed ?? this.moreFailed,
  );
}

final catalogListProvider =
    AsyncNotifierProvider<CatalogListController, CatalogListState>(
      CatalogListController.new,
      retry: noAutomaticRetry,
    );

class CatalogListController extends AsyncNotifier<CatalogListState> {
  /// Increases with every new query; a page that arrives for an older one is
  /// dropped, so a slow response can never replace newer results.
  int _generation = 0;

  @override
  Future<CatalogListState> build() async {
    final storeId = ref.watch(currentStoreIdProvider);
    final query = ref.watch(catalogQueryProvider);
    // Riverpod drops the result of a superseded build; the generation only
    // guards pages that loadMore started for an older query.
    _generation++;
    if (storeId == null) {
      return CatalogListState(
        query: query,
        items: const [],
        total: 0,
        hasMore: false,
      );
    }
    final page = await ref
        .read(catalogRepositoryProvider)
        .listProducts(storeId, query, limit: catalogPageSize);
    return CatalogListState(
      query: query,
      items: page.items,
      total: page.total,
      hasMore: page.hasMore,
    );
  }

  /// Loads the next page (incremental loading at the end of the list).
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
          .read(catalogRepositoryProvider)
          .listProducts(
            storeId,
            current.query,
            offset: current.items.length,
            limit: catalogPageSize,
          );
      if (generation != _generation) return;
      final seen = {for (final p in current.items) p.id};
      state = AsyncData(
        current.copyWith(
          items: [
            ...current.items,
            for (final p in page.items)
              if (!seen.contains(p.id)) p,
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

/// Counts for chips, Today and the setup checklist, and the categories.
final catalogSummaryProvider = FutureProvider<CatalogSummary?>(
  retry: noAutomaticRetry,
  (ref) async {
    final storeId = ref.watch(currentStoreIdProvider);
    if (storeId == null) return null;
    return ref.read(catalogRepositoryProvider).summary(storeId);
  },
);

// ---------------------------------------------------------------------------
// Product detail (PR-02) and history (PR-06).
// ---------------------------------------------------------------------------

final productProvider = FutureProvider.autoDispose.family<Product, String>(
  retry: noAutomaticRetry,
  (ref, productId) async {
    final storeId = ref.watch(currentStoreIdProvider);
    if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
    return ref.read(catalogRepositoryProvider).getProduct(storeId, productId);
  },
);

@immutable
class MovementsState {
  const MovementsState(
    this.items, {
    required this.hasMore,
    this.loadingMore = false,
  });
  final List<InventoryMovement> items;
  final bool hasMore;
  final bool loadingMore;
}

typedef MovementsKey = ({String productId, String? variantId});

final movementsProvider = AsyncNotifierProvider.autoDispose
    .family<MovementsController, MovementsState, MovementsKey>(
      MovementsController.new,
      retry: noAutomaticRetry,
    );

class MovementsController extends AsyncNotifier<MovementsState> {
  MovementsController(this.key);

  final MovementsKey key;

  @override
  Future<MovementsState> build() async {
    final storeId = ref.watch(currentStoreIdProvider);
    if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
    final (items, more) = await ref
        .read(catalogRepositoryProvider)
        .listMovements(storeId, key.productId, variantId: key.variantId);
    return MovementsState(items, hasMore: more);
  }

  Future<void> loadMore() async {
    final current = state.value;
    final storeId = ref.read(currentStoreIdProvider);
    if (current == null ||
        storeId == null ||
        !current.hasMore ||
        current.loadingMore) {
      return;
    }
    state = AsyncData(
      MovementsState(current.items, hasMore: true, loadingMore: true),
    );
    try {
      final (items, more) = await ref
          .read(catalogRepositoryProvider)
          .listMovements(
            storeId,
            key.productId,
            variantId: key.variantId,
            beforeId: current.items.last.id,
          );
      state = AsyncData(
        MovementsState([...current.items, ...items], hasMore: more),
      );
    } on ApiException {
      state = AsyncData(MovementsState(current.items, hasMore: true));
    }
  }
}

/// An image to display for a storage path (signed URL, cached by the store).
final productImageProvider = FutureProvider.autoDispose
    .family<ImageProvider, String>(
      retry: noAutomaticRetry,
      (ref, path) => ref.read(mediaStoreProvider).image(path),
    );

// ---------------------------------------------------------------------------
// Mutations. Each refreshes the affected reads only after the server confirmed.
// ---------------------------------------------------------------------------

final catalogActionsProvider = Provider<CatalogActions>(CatalogActions.new);

class CatalogActions {
  CatalogActions(this._ref);

  final Ref _ref;

  CatalogRepository get _repo => _ref.read(catalogRepositoryProvider);

  /// Calls [run] once more with the same idempotency key when the first
  /// answer was lost (timeout). The key makes the repeat safe: the server
  /// replays the first result instead of applying the change twice.
  Future<T> _withReplay<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException catch (e) {
      if (!e.outcomeUnknown) rethrow;
      return run();
    }
  }

  void _refreshLists() {
    _ref.invalidate(catalogListProvider);
    _ref.invalidate(catalogSummaryProvider);
  }

  /// Creates ([expectedVersion] null) or updates a product. Images the
  /// server no longer references are then removed from storage.
  Future<Product> saveProduct(
    String productId, {
    required int? expectedVersion,
    required ProductDraft draft,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final (product, removed) = await _withReplay(
      () => _repo.upsertProduct(
        storeId,
        productId,
        expectedVersion: expectedVersion,
        draft: draft,
        idempotencyKey: idempotencyKey,
      ),
    );
    unawaited(_ref.read(mediaStoreProvider).remove(removed));
    _refreshLists();
    _ref.invalidate(productProvider(productId));
    // A store with products can no longer change its currency.
    unawaited(
      _ref.read(workspaceProvider.notifier).refresh().catchError((_) {}),
    );
    return product;
  }

  Future<Product> setStatus(Product product, ProductStatus status) async {
    final storeId = _requireStore(_ref);
    final updated = await _withReplay(
      () => _repo.setStatus(
        storeId,
        product.id,
        expectedVersion: product.version,
        status: status,
      ),
    );
    _refreshLists();
    _ref.invalidate(productProvider(product.id));
    return updated;
  }

  Future<StockAdjustment> adjustStock({
    required String productId,
    required String variantId,
    required AdjustMode mode,
    required int quantity,
    required StockReason reason,
    String? note,
    required int expectedStock,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final result = await _withReplay(
      () => _repo.adjustStock(
        storeId,
        variantId,
        mode: mode,
        quantity: quantity,
        reason: reason,
        note: note,
        expectedStock: expectedStock,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refreshLists();
    _ref.invalidate(productProvider(productId));
    _ref.invalidate(movementsProvider);
    return result;
  }

  /// Uploads a prepared photo for [productId]; returns its storage path.
  Future<String> uploadImage(String productId, Uint8List sourceBytes) async {
    final storeId = _requireStore(_ref);
    final jpeg = await _ref.read(imagePreparerProvider)(sourceBytes);
    final path = productImagePath(storeId, productId);
    await _ref.read(mediaStoreProvider).upload(path, jpeg);
    return path;
  }

  /// Removes uploads that were never saved with a product (the seller
  /// discarded the editor). Referenced objects are refused by the server.
  Future<void> discardUploads(List<String> paths) =>
      _ref.read(mediaStoreProvider).remove(paths);
}
