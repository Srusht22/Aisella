import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/formatting/money.dart';

/// List-row view of a product (Phase 2 PR-01). Phase 6 replaces the sample
/// source with the `v_product_list` read.
@immutable
class ProductSummary {
  const ProductSummary({
    required this.id,
    required this.name,
    required this.priceMin,
    required this.priceMax,
    required this.variantCount,
    required this.stock,
    required this.lowStockThreshold,
    this.sku,
  });

  final String id;
  final String name;
  final String? sku;
  final int priceMin;
  final int priceMax;
  final int variantCount;
  final int stock;
  final int lowStockThreshold;

  bool get isOut => stock == 0;
  bool get isLow => stock > 0 && stock <= lowStockThreshold;
}

@immutable
class ProductList {
  const ProductList(
    this.items, {
    required this.currency,
    required this.isSample,
  });

  final List<ProductSummary> items;
  final Currency currency;
  final bool isSample;
}

abstract interface class ProductsRepository {
  Future<ProductList> list();
}

/// Phase 4 default without sample data: the catalog is genuinely empty.
class NotConnectedProductsRepository implements ProductsRepository {
  const NotConnectedProductsRepository();

  @override
  Future<ProductList> list() async =>
      const ProductList([], currency: Currency.iqd, isSample: false);
}

/// SAMPLE DATA — fictional catalog for design review (mixed Latin and
/// Sorani names, a very long name, low and out-of-stock items).
class SampleProductsRepository implements ProductsRepository {
  const SampleProductsRepository({
    this.latency = const Duration(milliseconds: 450),
  });

  final Duration latency;

  @override
  Future<ProductList> list() async {
    await Future<void>.delayed(latency);
    return const ProductList(
      [
        ProductSummary(
          id: 'p1',
          name: 'Beige Abaya',
          sku: 'ABY-BG',
          priceMin: 35000,
          priceMax: 35000,
          variantCount: 4,
          stock: 9,
          lowStockThreshold: 3,
        ),
        ProductSummary(
          id: 'p2',
          name: 'عەبای ڕەش — قوماشی نەرم',
          priceMin: 38000,
          priceMax: 42000,
          variantCount: 6,
          stock: 2,
          lowStockThreshold: 3,
        ),
        ProductSummary(
          id: 'p3',
          name: 'White Leather Sneakers with Extra-Long Product Name for Truncation Testing',
          sku: 'SNK-WHT-LONG',
          priceMin: 55000,
          priceMax: 55000,
          variantCount: 8,
          stock: 14,
          lowStockThreshold: 4,
        ),
        ProductSummary(
          id: 'p4',
          name: 'بۆنی گوڵی ئێواران 100ml',
          priceMin: 65000,
          priceMax: 65000,
          variantCount: 1,
          stock: 0,
          lowStockThreshold: 2,
        ),
        ProductSummary(
          id: 'p5',
          name: 'Phone case — iPhone 15',
          sku: 'CASE-I15',
          priceMin: 12000,
          priceMax: 15000,
          variantCount: 3,
          stock: 31,
          lowStockThreshold: 5,
        ),
        ProductSummary(
          id: 'p6',
          name: 'جانتای دەستی بچووک',
          priceMin: 27000,
          priceMax: 27000,
          variantCount: 2,
          stock: 1,
          lowStockThreshold: 2,
        ),
      ],
      currency: Currency.iqd,
      isSample: true,
    );
  }
}

final productsRepositoryProvider = Provider<ProductsRepository>(
  (ref) => ref.watch(appConfigProvider).sampleData
      ? const SampleProductsRepository()
      : const NotConnectedProductsRepository(),
);

final productListProvider = FutureProvider<ProductList>(
  (ref) => ref.watch(productsRepositoryProvider).list(),
);

/// Product list filters (Phase 2 PR-01 chips; Inactive/Archived arrive with
/// catalog management).
enum ProductFilter { all, lowStock, outOfStock }

@immutable
class ProductQuery {
  const ProductQuery({this.text = '', this.filter = ProductFilter.all});

  final String text;
  final ProductFilter filter;

  bool get isActive => text.isNotEmpty || filter != ProductFilter.all;

  /// Case-insensitive match on name or SKU; digits typed in any style match.
  bool matches(ProductSummary p) {
    final q = Digits.normalize(text).trim().toLowerCase();
    final textOk =
        q.isEmpty ||
        Digits.normalize(p.name).toLowerCase().contains(q) ||
        (p.sku?.toLowerCase().contains(q) ?? false);
    final filterOk = switch (filter) {
      ProductFilter.all => true,
      ProductFilter.lowStock => p.isLow,
      ProductFilter.outOfStock => p.isOut,
    };
    return textOk && filterOk;
  }
}

class ProductQueryController extends Notifier<ProductQuery> {
  @override
  ProductQuery build() => const ProductQuery();

  void setText(String text) =>
      state = ProductQuery(text: text, filter: state.filter);
  void setFilter(ProductFilter f) =>
      state = ProductQuery(text: state.text, filter: f);
  void clear() => state = const ProductQuery();
}

final productQueryProvider =
    NotifierProvider<ProductQueryController, ProductQuery>(
      ProductQueryController.new,
    );
