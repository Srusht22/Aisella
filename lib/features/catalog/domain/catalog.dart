import 'package:flutter/foundation.dart';

/// Catalog and inventory entities as the server returns them (the contract of
/// `api.get_product`, `api.list_products`, `api.list_inventory_movements`;
/// docs/implementation/phase-6). Server state: never edited in place —
/// changes go through the catalog repository and come back from the server.

enum ProductStatus {
  active,
  inactive,
  archived;

  static ProductStatus parse(Object? v) => switch (v) {
    'inactive' => ProductStatus.inactive,
    'archived' => ProductStatus.archived,
    _ => ProductStatus.active,
  };
}

/// Stock state (Phase 2 §2.4, Phase 1 BR-16/BR-18).
enum StockStatus {
  inStock,
  low,
  out,

  /// Untracked and available.
  available,

  /// Untracked and unavailable.
  unavailable;

  static StockStatus parse(Object? v) => switch (v) {
    'low' => StockStatus.low,
    'out' => StockStatus.out,
    'available' => StockStatus.available,
    'unavailable' => StockStatus.unavailable,
    _ => StockStatus.inStock,
  };

  bool get needsAttention => this == low || this == out || this == unavailable;
}

/// One row of the product list (PR-01).
@immutable
class ProductSummary {
  const ProductSummary({
    required this.id,
    required this.name,
    required this.status,
    required this.trackStock,
    required this.priceMin,
    required this.priceMax,
    required this.variantCount,
    required this.stockTotal,
    required this.lowCount,
    required this.outCount,
    required this.stockStatus,
    required this.version,
    this.category,
    this.imagePath,
  });

  factory ProductSummary.fromJson(Map<String, dynamic> j) => ProductSummary(
    id: j['id'] as String,
    name: j['name'] as String,
    category: j['category'] as String?,
    status: ProductStatus.parse(j['status']),
    trackStock: j['track_stock'] as bool? ?? true,
    priceMin: (j['price_min'] as num?)?.toInt() ?? 0,
    priceMax: (j['price_max'] as num?)?.toInt() ?? 0,
    variantCount: (j['variant_count'] as num?)?.toInt() ?? 0,
    stockTotal: (j['stock_total'] as num?)?.toInt() ?? 0,
    lowCount: (j['low_count'] as num?)?.toInt() ?? 0,
    outCount: (j['out_count'] as num?)?.toInt() ?? 0,
    stockStatus: StockStatus.parse(j['stock_state']),
    imagePath: j['image_path'] as String?,
    version: (j['version'] as num?)?.toInt() ?? 1,
  );

  final String id;
  final String name;
  final String? category;
  final ProductStatus status;
  final bool trackStock;
  final int priceMin;
  final int priceMax;

  /// Active variants.
  final int variantCount;

  /// Sum of active variants' stock (tracked products only).
  final int stockTotal;

  /// Active variants at or below their threshold (including empty ones).
  final int lowCount;
  final int outCount;
  final StockStatus stockStatus;
  final String? imagePath;
  final int version;
}

@immutable
class Variant {
  const Variant({
    required this.id,
    required this.optionValues,
    required this.label,
    required this.price,
    required this.stockOnHand,
    required this.available,
    required this.archived,
    required this.hasHistory,
    this.sku,
    this.priceOverride,
    this.lowStockThreshold,
  });

  factory Variant.fromJson(Map<String, dynamic> j) => Variant(
    id: j['id'] as String,
    optionValues: [for (final v in j['option_values'] as List? ?? []) '$v'],
    label: j['label'] as String? ?? '',
    sku: j['sku'] as String?,
    priceOverride: (j['price_override'] as num?)?.toInt(),
    price: (j['price'] as num).toInt(),
    stockOnHand: (j['stock_on_hand'] as num?)?.toInt() ?? 0,
    available: j['available'] as bool? ?? true,
    lowStockThreshold: (j['low_stock_threshold'] as num?)?.toInt(),
    archived: j['status'] == 'archived',
    hasHistory: j['has_history'] as bool? ?? false,
  );

  final String id;
  final List<String> optionValues;

  /// Option values joined for display ("M · Black"); empty for the default
  /// variant of a product without options.
  final String label;
  final String? sku;
  final int? priceOverride;

  /// Effective price: the override or the product price.
  final int price;
  final int stockOnHand;

  /// For untracked products: the manual availability switch (BR-16).
  final bool available;

  /// Own threshold; null means the store default.
  final int? lowStockThreshold;
  final bool archived;

  /// Whether stock movements exist (then the variant can only be archived).
  final bool hasHistory;

  int thresholdWith(int storeDefault) => lowStockThreshold ?? storeDefault;

  StockStatus statusFor({required bool tracked, required int storeDefault}) {
    if (!tracked) {
      return available ? StockStatus.available : StockStatus.unavailable;
    }
    if (stockOnHand == 0) return StockStatus.out;
    if (stockOnHand <= thresholdWith(storeDefault)) return StockStatus.low;
    return StockStatus.inStock;
  }
}

@immutable
class ProductImageRef {
  const ProductImageRef({required this.path, required this.position});

  factory ProductImageRef.fromJson(Map<String, dynamic> j) => ProductImageRef(
    path: j['path'] as String,
    position: (j['position'] as num).toInt(),
  );

  /// Storage object path `{store_id}/products/{product_id}/{uuid}.jpg`.
  final String path;
  final int position;
}

@immutable
class Product {
  const Product({
    required this.id,
    required this.name,
    required this.basePrice,
    required this.trackStock,
    required this.optionTypes,
    required this.status,
    required this.version,
    required this.lowStockDefault,
    required this.variants,
    required this.images,
    this.description,
    this.category,
  });

  factory Product.fromJson(Map<String, dynamic> j) => Product(
    id: j['id'] as String,
    name: j['name'] as String,
    description: j['description'] as String?,
    category: j['category'] as String?,
    basePrice: (j['base_price'] as num).toInt(),
    trackStock: j['track_stock'] as bool? ?? true,
    optionTypes: [for (final t in j['option_types'] as List? ?? []) '$t'],
    status: ProductStatus.parse(j['status']),
    version: (j['version'] as num).toInt(),
    lowStockDefault: (j['low_stock_default'] as num?)?.toInt() ?? 3,
    variants: [
      for (final v in j['variants'] as List? ?? [])
        Variant.fromJson((v as Map).cast<String, dynamic>()),
    ],
    images: [
      for (final i in j['images'] as List? ?? [])
        ProductImageRef.fromJson((i as Map).cast<String, dynamic>()),
    ],
  );

  final String id;
  final String name;
  final String? description;
  final String? category;
  final int basePrice;
  final bool trackStock;
  final List<String> optionTypes;
  final ProductStatus status;
  final int version;
  final int lowStockDefault;
  final List<Variant> variants;
  final List<ProductImageRef> images;

  bool get hasOptions => optionTypes.isNotEmpty;
  List<Variant> get activeVariants => [
    for (final v in variants)
      if (!v.archived) v,
  ];

  /// The default variant of a product without options.
  Variant? get defaultVariant => hasOptions ? null : activeVariants.firstOrNull;

  StockStatus statusOf(Variant v) =>
      v.statusFor(tracked: trackStock, storeDefault: lowStockDefault);
}

/// The reasons a seller can choose when adjusting stock (Phase 2 PR-05);
/// the order reasons are written by order processing (Phase 7).
enum StockReason {
  received('received'),
  soldInShop('sold_in_shop'),
  damaged('damaged'),
  countCorrection('count_correction'),
  other('other'),
  initialStock('initial_stock'),
  orderApproved('order_approved'),
  orderEdited('order_edited'),
  orderCancelled('order_cancelled'),
  orderReturned('order_returned_restock');

  const StockReason(this.wire);
  final String wire;

  static const manual = [received, soldInShop, damaged, countCorrection, other];

  static StockReason parse(Object? v) =>
      values.firstWhere((r) => r.wire == v, orElse: () => other);
}

enum AdjustMode { add, remove, set }

/// Who made a stock movement, relative to the viewer.
enum MovementActor { you, member, system }

@immutable
class InventoryMovement {
  const InventoryMovement({
    required this.id,
    required this.variantId,
    required this.variantLabel,
    required this.delta,
    required this.resultingQty,
    required this.reason,
    required this.createdAt,
    required this.actor,
    this.note,
  });

  factory InventoryMovement.fromJson(Map<String, dynamic> j) =>
      InventoryMovement(
        id: (j['id'] as num).toInt(),
        variantId: j['variant_id'] as String,
        variantLabel: j['variant_label'] as String? ?? '',
        delta: (j['delta'] as num).toInt(),
        resultingQty: (j['resulting_qty'] as num).toInt(),
        reason: StockReason.parse(j['reason']),
        note: j['note'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
        actor: switch (j['actor']) {
          'you' => MovementActor.you,
          'member' => MovementActor.member,
          _ => MovementActor.system,
        },
      );

  final int id;
  final String variantId;
  final String variantLabel;
  final int delta;
  final int resultingQty;
  final StockReason reason;
  final String? note;
  final DateTime createdAt;
  final MovementActor actor;
}

/// Result of a confirmed stock adjustment.
@immutable
class StockAdjustment {
  const StockAdjustment({
    required this.variantId,
    required this.productId,
    required this.previousStock,
    required this.stockOnHand,
  });

  factory StockAdjustment.fromJson(Map<String, dynamic> j) => StockAdjustment(
    variantId: j['variant_id'] as String,
    productId: j['product_id'] as String,
    previousStock: (j['previous_stock'] as num).toInt(),
    stockOnHand: (j['stock_on_hand'] as num).toInt(),
  );

  final String variantId;
  final String productId;
  final int previousStock;
  final int stockOnHand;
}

/// Product list filters (Phase 2 PR-01 chips).
enum CatalogFilter {
  all('all'),
  low('low'),
  out('out'),
  inactive('inactive'),
  archived('archived');

  const CatalogFilter(this.wire);
  final String wire;
}

enum CatalogSort {
  updated('updated'),
  name('name'),
  priceAsc('price_asc'),
  priceDesc('price_desc'),
  stockAsc('stock_asc');

  const CatalogSort(this.wire);
  final String wire;
}

@immutable
class CatalogQuery {
  const CatalogQuery({
    this.text = '',
    this.filter = CatalogFilter.all,
    this.category,
    this.sort = CatalogSort.updated,
  });

  final String text;
  final CatalogFilter filter;
  final String? category;
  final CatalogSort sort;

  bool get isDefault =>
      text.trim().isEmpty &&
      filter == CatalogFilter.all &&
      category == null &&
      sort == CatalogSort.updated;

  CatalogQuery copyWith({
    String? text,
    CatalogFilter? filter,
    String? Function()? category,
    CatalogSort? sort,
  }) => CatalogQuery(
    text: text ?? this.text,
    filter: filter ?? this.filter,
    category: category != null ? category() : this.category,
    sort: sort ?? this.sort,
  );

  @override
  bool operator ==(Object other) =>
      other is CatalogQuery &&
      other.text == text &&
      other.filter == filter &&
      other.category == category &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(text, filter, category, sort);
}

@immutable
class CatalogPage {
  const CatalogPage({
    required this.items,
    required this.total,
    required this.hasMore,
  });

  factory CatalogPage.fromJson(Map<String, dynamic> j) => CatalogPage(
    items: [
      for (final i in j['items'] as List? ?? [])
        ProductSummary.fromJson((i as Map).cast<String, dynamic>()),
    ],
    total: (j['total'] as num?)?.toInt() ?? 0,
    hasMore: j['has_more'] as bool? ?? false,
  );

  final List<ProductSummary> items;
  final int total;
  final bool hasMore;
}

@immutable
class CategoryCount {
  const CategoryCount(this.name, this.count);
  final String name;
  final int count;
}

@immutable
class CatalogSummary {
  const CatalogSummary({
    required this.total,
    required this.all,
    required this.low,
    required this.out,
    required this.inactive,
    required this.archived,
    required this.categories,
    required this.lowStockDefault,
  });

  factory CatalogSummary.fromJson(Map<String, dynamic> j) => CatalogSummary(
    total: (j['total'] as num?)?.toInt() ?? 0,
    all: (j['all'] as num?)?.toInt() ?? 0,
    low: (j['low'] as num?)?.toInt() ?? 0,
    out: (j['out'] as num?)?.toInt() ?? 0,
    inactive: (j['inactive'] as num?)?.toInt() ?? 0,
    archived: (j['archived'] as num?)?.toInt() ?? 0,
    categories: [
      for (final c in j['categories'] as List? ?? [])
        CategoryCount(
          (c as Map)['name'] as String,
          (c['count'] as num).toInt(),
        ),
    ],
    lowStockDefault: (j['low_stock_default'] as num?)?.toInt() ?? 3,
  );

  /// Every product, archived included (setup checklist: "first product").
  final int total;

  /// Not archived.
  final int all;
  final int low;

  /// Out of stock, plus unavailable untracked products.
  final int out;
  final int inactive;
  final int archived;
  final List<CategoryCount> categories;
  final int lowStockDefault;

  /// Products needing attention (Today "Low or out of stock").
  int get attention => low + out;
}
