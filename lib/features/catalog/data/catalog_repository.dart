import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/api.dart';
import '../domain/catalog.dart';
import '../domain/product_draft.dart';

/// Catalog and inventory reads and writes (`api.*` functions; Phase 3
/// contracts §3.3). Every call is authorised by the database: a product of
/// another store is NOT_FOUND whatever ids are sent.
abstract interface class CatalogRepository {
  Future<CatalogPage> listProducts(
    String storeId,
    CatalogQuery query, {
    int offset = 0,
    int limit = 30,
  });

  Future<CatalogSummary> summary(String storeId);

  Future<Product> getProduct(String storeId, String productId);

  /// Creates ([expectedVersion] null) or updates a product. Returns the saved
  /// product and the image paths the server no longer references.
  Future<(Product, List<String>)> upsertProduct(
    String storeId,
    String productId, {
    required int? expectedVersion,
    required ProductDraft draft,
    required String idempotencyKey,
  });

  Future<Product> setStatus(
    String storeId,
    String productId, {
    required int expectedVersion,
    required ProductStatus status,
  });

  Future<StockAdjustment> adjustStock(
    String storeId,
    String variantId, {
    required AdjustMode mode,
    required int quantity,
    required StockReason reason,
    String? note,
    int? expectedStock,
    required String idempotencyKey,
  });

  Future<(List<InventoryMovement>, bool)> listMovements(
    String storeId,
    String productId, {
    String? variantId,
    int? beforeId,
    int limit = 50,
  });
}

class SupabaseCatalogRepository implements CatalogRepository {
  SupabaseCatalogRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<CatalogPage> listProducts(
    String storeId,
    CatalogQuery query, {
    int offset = 0,
    int limit = 30,
  }) async => CatalogPage.fromJson(
    await callApi(
      _client,
      'list_products',
      params: {
        'p_store_id': storeId,
        'p_query': query.text.trim().isEmpty ? null : query.text.trim(),
        'p_filter': query.filter.wire,
        'p_category': query.category,
        'p_sort': query.sort.wire,
        'p_limit': limit,
        'p_offset': offset,
      },
    ),
  );

  @override
  Future<CatalogSummary> summary(String storeId) async =>
      CatalogSummary.fromJson(
        await callApi(
          _client,
          'catalog_summary',
          params: {'p_store_id': storeId},
        ),
      );

  @override
  Future<Product> getProduct(String storeId, String productId) async =>
      Product.fromJson(
        await callApi(
          _client,
          'get_product',
          params: {'p_store_id': storeId, 'p_product_id': productId},
        ),
      );

  @override
  Future<(Product, List<String>)> upsertProduct(
    String storeId,
    String productId, {
    required int? expectedVersion,
    required ProductDraft draft,
    required String idempotencyKey,
  }) async {
    final data = await callApi(
      _client,
      'upsert_product',
      params: {
        'p_store_id': storeId,
        'p_product_id': productId,
        'p_expected_version': expectedVersion,
        'p_product': draft.toJson(),
        'p_idempotency_key': idempotencyKey,
      },
    );
    return (
      Product.fromJson(data),
      [for (final p in data['removed_image_paths'] as List? ?? []) '$p'],
    );
  }

  @override
  Future<Product> setStatus(
    String storeId,
    String productId, {
    required int expectedVersion,
    required ProductStatus status,
  }) async => Product.fromJson(
    await callApi(
      _client,
      'set_product_status',
      params: {
        'p_store_id': storeId,
        'p_product_id': productId,
        'p_expected_version': expectedVersion,
        'p_status': status.name,
      },
    ),
  );

  @override
  Future<StockAdjustment> adjustStock(
    String storeId,
    String variantId, {
    required AdjustMode mode,
    required int quantity,
    required StockReason reason,
    String? note,
    int? expectedStock,
    required String idempotencyKey,
  }) async => StockAdjustment.fromJson(
    await callApi(
      _client,
      'adjust_stock',
      params: {
        'p_store_id': storeId,
        'p_variant_id': variantId,
        'p_mode': mode.name,
        'p_quantity': quantity,
        'p_reason': reason.wire,
        'p_note': note,
        'p_expected_stock': expectedStock,
        'p_idempotency_key': idempotencyKey,
      },
    ),
  );

  @override
  Future<(List<InventoryMovement>, bool)> listMovements(
    String storeId,
    String productId, {
    String? variantId,
    int? beforeId,
    int limit = 50,
  }) async {
    final data = await callApi(
      _client,
      'list_inventory_movements',
      params: {
        'p_store_id': storeId,
        'p_product_id': productId,
        'p_variant_id': variantId,
        'p_limit': limit,
        'p_before_id': beforeId,
      },
    );
    return (
      [
        for (final m in data['items'] as List? ?? [])
          InventoryMovement.fromJson((m as Map).cast<String, dynamic>()),
      ],
      data['has_more'] as bool? ?? false,
    );
  }
}

final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => SupabaseCatalogRepository(ref.watch(supabaseClientProvider)),
);
