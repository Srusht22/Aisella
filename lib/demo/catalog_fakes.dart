import 'dart:async';
import 'dart:typed_data';

import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/core/backend/idempotency.dart';
import 'package:aisellia/features/catalog/data/catalog_repository.dart';
import 'package:aisellia/features/catalog/data/media_store.dart';
import 'package:aisellia/features/catalog/domain/catalog.dart';
import 'package:aisellia/features/catalog/domain/product_draft.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

/// In-memory catalog with the server's rules that the UI depends on: stock
/// states and filters, idempotent writes, versions, never-negative stock,
/// movements. Records calls for assertions.
class FakeCatalogRepository implements CatalogRepository {
  FakeCatalogRepository({
    List<Product> products = const [],
    this.lowStockDefault = 3,
  }) {
    for (final p in products) {
      _products[p.id] = p;
    }
  }

  final int lowStockDefault;
  final _products = <String, Product>{};
  final _movements = <InventoryMovement>[];
  final _keys = <String, Object>{};
  final calls = <String>[];
  var _movementId = 100;

  /// The next call fails with this error (then it is cleared).
  ApiException? failNext;

  /// Delay before every answer (loading states).
  Duration delay = Duration.zero;

  Future<void> _step(String call) async {
    calls.add(call);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  Product? product(String id) => _products[id];

  ProductSummary _summary(Product p) {
    final active = p.activeVariants;
    final prices = active.map((v) => v.price).toList();
    final low = active
        .where((v) => v.stockOnHand <= v.thresholdWith(lowStockDefault))
        .length;
    final out = active.where((v) => v.stockOnHand == 0).length;
    final state = !p.trackStock
        ? (active.any((v) => v.available) ? 'available' : 'unavailable')
        : active.isNotEmpty && out == active.length
        ? 'out'
        : low > 0
        ? 'low'
        : 'in';
    return ProductSummary(
      id: p.id,
      name: p.name,
      category: p.category,
      status: p.status,
      trackStock: p.trackStock,
      priceMin: prices.isEmpty
          ? p.basePrice
          : prices.reduce((a, b) => a < b ? a : b),
      priceMax: prices.isEmpty
          ? p.basePrice
          : prices.reduce((a, b) => a > b ? a : b),
      variantCount: active.length,
      stockTotal: active.fold(0, (s, v) => s + v.stockOnHand),
      lowCount: low,
      outCount: out,
      stockStatus: StockStatus.parse(state),
      imagePath: p.images.firstOrNull?.path,
      version: p.version,
    );
  }

  bool _matches(ProductSummary s, CatalogFilter f) => switch (f) {
    CatalogFilter.all => s.status != ProductStatus.archived,
    CatalogFilter.low =>
      s.status != ProductStatus.archived && s.stockStatus == StockStatus.low,
    CatalogFilter.out =>
      s.status != ProductStatus.archived &&
          (s.stockStatus == StockStatus.out ||
              s.stockStatus == StockStatus.unavailable),
    CatalogFilter.inactive => s.status == ProductStatus.inactive,
    CatalogFilter.archived => s.status == ProductStatus.archived,
  };

  @override
  Future<CatalogPage> listProducts(
    String storeId,
    CatalogQuery query, {
    int offset = 0,
    int limit = 30,
  }) async {
    await _step(
      'list:${query.text}|${query.filter.name}|${query.category}|${query.sort.name}|$offset',
    );
    final q = query.text.trim().toLowerCase();
    var rows = [
      for (final p in _products.values)
        if ((q.isEmpty ||
                '${p.name} ${p.category ?? ''} ${p.variants.map((v) => '${v.label} ${v.sku ?? ''}').join(' ')}'
                    .toLowerCase()
                    .contains(q)) &&
            (query.category == null ||
                p.category?.toLowerCase() == query.category!.toLowerCase()))
          _summary(p),
    ].where((s) => _matches(s, query.filter)).toList();
    rows.sort(switch (query.sort) {
      CatalogSort.name => (a, b) => a.name.toLowerCase().compareTo(
        b.name.toLowerCase(),
      ),
      CatalogSort.priceAsc => (a, b) => a.priceMin.compareTo(b.priceMin),
      CatalogSort.priceDesc => (a, b) => b.priceMax.compareTo(a.priceMax),
      CatalogSort.stockAsc => (a, b) => a.stockTotal.compareTo(b.stockTotal),
      CatalogSort.updated => (a, b) => 0,
    });
    final page = rows.skip(offset).take(limit).toList();
    rows = rows;
    return CatalogPage(
      items: page,
      total: rows.length,
      hasMore: rows.length > offset + limit,
    );
  }

  @override
  Future<CatalogSummary> summary(String storeId) async {
    await _step('summary');
    final all = _products.values.map(_summary).toList();
    int n(CatalogFilter f) => all.where((s) => _matches(s, f)).length;
    final categories = <String, int>{};
    for (final p in _products.values) {
      if (p.category != null && p.status != ProductStatus.archived) {
        categories[p.category!] = (categories[p.category!] ?? 0) + 1;
      }
    }
    return CatalogSummary(
      total: all.length,
      all: n(CatalogFilter.all),
      low: n(CatalogFilter.low),
      out: n(CatalogFilter.out),
      inactive: n(CatalogFilter.inactive),
      archived: n(CatalogFilter.archived),
      categories: [
        for (final e in categories.entries) CategoryCount(e.key, e.value),
      ],
      lowStockDefault: lowStockDefault,
    );
  }

  @override
  Future<Product> getProduct(String storeId, String productId) async {
    await _step('get:$productId');
    return _products[productId] ??
        (throw const ApiException(ApiErrorCode.notFound));
  }

  @override
  Future<(Product, List<String>)> upsertProduct(
    String storeId,
    String productId, {
    required int? expectedVersion,
    required ProductDraft draft,
    required String idempotencyKey,
  }) async {
    await _step('upsert:$productId:${draft.name}');
    final replay = _keys[idempotencyKey];
    if (replay is (Product, List<String>)) return replay;
    final existing = _products[productId];
    if (existing != null && existing.version != expectedVersion) {
      throw ApiException(
        ApiErrorCode.conflictVersion,
        currentVersion: existing.version,
      );
    }
    final variants = <Variant>[];
    for (final v in draft.variants) {
      final old = existing?.variants.where((x) => x.id == v.id).firstOrNull;
      final stock = old?.stockOnHand ?? (draft.trackStock ? v.initialStock : 0);
      final variant = Variant(
        id: v.id ?? newIdempotencyKey(),
        optionValues: v.optionValues,
        label: v.label,
        sku: v.sku.isEmpty ? null : v.sku,
        priceOverride: v.priceOverride,
        price: v.priceOverride ?? draft.basePrice!,
        stockOnHand: stock,
        available: v.available,
        lowStockThreshold: v.lowStockThreshold,
        archived: v.archived,
        hasHistory: old?.hasHistory ?? stock > 0,
      );
      variants.add(variant);
      if (old == null && stock > 0) {
        _record(variant, stock, stock, StockReason.initialStock);
      }
    }
    final product = Product(
      id: productId,
      name: draft.name.trim(),
      description: draft.description.trim().isEmpty
          ? null
          : draft.description.trim(),
      category: draft.category.trim().isEmpty ? null : draft.category.trim(),
      basePrice: draft.basePrice!,
      trackStock: draft.trackStock,
      optionTypes: [for (final t in draft.optionTypes) t.name],
      status: existing?.status == ProductStatus.archived
          ? ProductStatus.archived
          : draft.active
          ? ProductStatus.active
          : ProductStatus.inactive,
      version: (existing?.version ?? 0) + 1,
      lowStockDefault: lowStockDefault,
      variants: variants,
      images: [
        for (final (i, p) in draft.images.indexed)
          ProductImageRef(path: p, position: i),
      ],
    );
    _products[productId] = product;
    final removed = [
      for (final i in existing?.images ?? const <ProductImageRef>[])
        if (!draft.images.contains(i.path)) i.path,
    ];
    final result = (product, removed);
    _keys[idempotencyKey] = result;
    return result;
  }

  @override
  Future<Product> setStatus(
    String storeId,
    String productId, {
    required int expectedVersion,
    required ProductStatus status,
  }) async {
    await _step('status:$productId:${status.name}');
    final p = _products[productId]!;
    if (p.status == status) return p;
    if (p.version != expectedVersion) {
      throw ApiException(
        ApiErrorCode.conflictVersion,
        currentVersion: p.version,
      );
    }
    return _products[productId] = _copy(
      p,
      status: status,
      version: p.version + 1,
    );
  }

  Product _copy(
    Product p, {
    ProductStatus? status,
    int? version,
    List<Variant>? variants,
  }) => Product(
    id: p.id,
    name: p.name,
    description: p.description,
    category: p.category,
    basePrice: p.basePrice,
    trackStock: p.trackStock,
    optionTypes: p.optionTypes,
    status: status ?? p.status,
    version: version ?? p.version,
    lowStockDefault: p.lowStockDefault,
    variants: variants ?? p.variants,
    images: p.images,
  );

  void _record(
    Variant v,
    int delta,
    int result,
    StockReason reason, {
    String? note,
  }) {
    _movements.insert(
      0,
      InventoryMovement(
        id: _movementId++,
        variantId: v.id,
        variantLabel: v.label,
        delta: delta,
        resultingQty: result,
        reason: reason,
        note: note,
        createdAt: DateTime(2026, 10, 15, 9, 30),
        actor: MovementActor.you,
      ),
    );
  }

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
  }) async {
    await _step('adjust:$variantId:${mode.name}:$quantity:${reason.wire}');
    final replay = _keys[idempotencyKey];
    if (replay is StockAdjustment) return replay;
    final product = _products.values.firstWhere(
      (p) => p.variants.any((v) => v.id == variantId),
    );
    final v = product.variants.firstWhere((v) => v.id == variantId);
    if (expectedStock != null && expectedStock != v.stockOnHand) {
      throw ApiException(
        ApiErrorCode.stockChanged,
        details: {'current_stock': v.stockOnHand},
      );
    }
    final result = adjustmentResult(mode, v.stockOnHand, quantity)!;
    if (result < 0) {
      throw ApiException(
        ApiErrorCode.insufficientStock,
        details: {'current_stock': v.stockOnHand},
      );
    }
    final updated = Variant(
      id: v.id,
      optionValues: v.optionValues,
      label: v.label,
      sku: v.sku,
      priceOverride: v.priceOverride,
      price: v.price,
      stockOnHand: result,
      available: v.available,
      lowStockThreshold: v.lowStockThreshold,
      archived: v.archived,
      hasHistory: true,
    );
    _products[product.id] = _copy(
      product,
      variants: [for (final x in product.variants) x.id == v.id ? updated : x],
    );
    _record(updated, result - v.stockOnHand, result, reason, note: note);
    final adj = StockAdjustment(
      variantId: v.id,
      productId: product.id,
      previousStock: v.stockOnHand,
      stockOnHand: result,
    );
    _keys[idempotencyKey] = adj;
    return adj;
  }

  /// The product holding [variantId], if any.
  Product? productOfVariant(String variantId) => _products.values
      .where((p) => p.variants.any((v) => v.id == variantId))
      .firstOrNull;

  /// Order stock moves (approval, edit, cancel, return), as the order
  /// functions do on the server.
  void moveStock(String variantId, int delta, StockReason reason) {
    final p = productOfVariant(variantId)!;
    _products[p.id] = _copy(
      p,
      variants: [
        for (final v in p.variants)
          if (v.id != variantId)
            v
          else
            Variant(
              id: v.id,
              optionValues: v.optionValues,
              label: v.label,
              sku: v.sku,
              priceOverride: v.priceOverride,
              price: v.price,
              stockOnHand: v.stockOnHand + delta,
              available: v.available,
              lowStockThreshold: v.lowStockThreshold,
              archived: v.archived,
              hasHistory: true,
            ),
      ],
    );
    final v = _products[p.id]!.variants.firstWhere((x) => x.id == variantId);
    _record(v, delta, v.stockOnHand, reason);
  }

  /// Simulates a catalog price change made elsewhere.
  void setPriceElsewhere(String productId, int price) {
    final p = _products[productId]!;
    _products[productId] = Product(
      id: p.id,
      name: p.name,
      description: p.description,
      category: p.category,
      basePrice: price,
      trackStock: p.trackStock,
      optionTypes: p.optionTypes,
      status: p.status,
      version: p.version + 1,
      lowStockDefault: p.lowStockDefault,
      variants: [
        for (final v in p.variants)
          Variant(
            id: v.id,
            optionValues: v.optionValues,
            label: v.label,
            sku: v.sku,
            price: price,
            stockOnHand: v.stockOnHand,
            available: v.available,
            archived: v.archived,
            hasHistory: v.hasHistory,
          ),
      ],
      images: p.images,
    );
  }

  /// Simulates a change made on another device.
  void setStockElsewhere(String productId, int stock) {
    final p = _products[productId]!;
    final v = p.variants.first;
    _products[productId] = _copy(
      p,
      variants: [
        Variant(
          id: v.id,
          optionValues: v.optionValues,
          label: v.label,
          sku: v.sku,
          price: v.price,
          stockOnHand: stock,
          available: v.available,
          archived: v.archived,
          hasHistory: true,
        ),
        ...p.variants.skip(1),
      ],
    );
  }

  @override
  Future<(List<InventoryMovement>, bool)> listMovements(
    String storeId,
    String productId, {
    String? variantId,
    int? beforeId,
    int limit = 50,
  }) async {
    await _step('movements:$productId');
    final ids = {
      for (final v in _products[productId]?.variants ?? const <Variant>[]) v.id,
    };
    return (
      [
        for (final m in _movements)
          if (ids.contains(m.variantId) &&
              (variantId == null || m.variantId == variantId))
            m,
      ],
      false,
    );
  }
}

/// A tiny real image so `Image` widgets decode without network access.
final Uint8List testPng = Uint8List.fromList(
  img.encodePng(
    img.fill(
      img.Image(width: 8, height: 8),
      color: img.ColorRgb8(196, 160, 120),
    ),
  ),
);

class FakeMediaStore implements MediaStore {
  final uploaded = <String, Uint8List>{};
  final removed = <String>[];
  MediaFailure? failNextUpload;
  Completer<void>? holdUploads;

  @override
  Future<void> upload(String path, Uint8List jpeg) async {
    if (holdUploads != null) await holdUploads!.future;
    final f = failNextUpload;
    if (f != null) {
      failNextUpload = null;
      throw MediaException(f);
    }
    uploaded[path] = jpeg;
  }

  @override
  Future<ImageProvider> image(String path) async => MemoryImage(testPng);

  @override
  Future<void> remove(List<String> paths) async => removed.addAll(paths);
}

class FakePhotoPicker implements PhotoPicker {
  FakePhotoPicker([Uint8List? bytes])
    : bytes =
          bytes ??
          img.encodeJpg(
            img.fill(
              img.Image(width: 40, height: 30),
              color: img.ColorRgb8(30, 90, 160),
            ),
          );

  final Uint8List bytes;
  final picks = <PhotoSource>[];

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    picks.add(source);
    return bytes;
  }
}

/// Builds a product as the server would return it.
Product testProduct({
  String id = 'p-abaya',
  String name = 'Black Abaya',
  String? category = 'Clothing',
  int price = 35000,
  bool track = true,
  ProductStatus status = ProductStatus.active,
  List<(String, int)> variants = const [('', 12)],
  List<String> images = const [],
  String? sku,
}) => Product(
  id: id,
  name: name,
  category: category,
  basePrice: price,
  trackStock: track,
  optionTypes: variants.length > 1 || variants.first.$1.isNotEmpty
      ? const ['Size']
      : const [],
  status: status,
  version: 1,
  lowStockDefault: 3,
  variants: [
    for (final (i, (label, stock)) in variants.indexed)
      Variant(
        id: '$id-v$i',
        optionValues: label.isEmpty ? const [] : [label],
        label: label,
        sku: i == 0 ? sku : null,
        price: price,
        stockOnHand: stock,
        available: true,
        archived: false,
        hasHistory: stock > 0,
      ),
  ],
  images: [
    for (final (i, p) in images.indexed) ProductImageRef(path: p, position: i),
  ],
);

/// A small realistic catalog (mixed scripts, low and out of stock, an
/// untracked product, an inactive one).
List<Product> sampleCatalog() => [
  testProduct(images: const ['s/products/p-abaya/a.jpg'], sku: 'ABY-BLK'),
  testProduct(
    id: 'p-shirt',
    name: 'Linen Shirt',
    price: 25000,
    variants: const [('S', 2), ('M', 0), ('L', 9)],
  ),
  testProduct(
    id: 'p-oud',
    name: 'بۆنی عود',
    category: 'Perfumes',
    price: 15000,
    track: false,
  ),
  testProduct(
    id: 'p-bag',
    name: 'Leather Bag',
    category: 'Shoes and bags',
    price: 50000,
    variants: const [('', 0)],
  ),
  testProduct(
    id: 'p-cable',
    name: 'USB-C Cable',
    category: null,
    price: 5000,
    status: ProductStatus.inactive,
    variants: const [('', 40)],
  ),
];
