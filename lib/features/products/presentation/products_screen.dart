import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/formatting/money.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/media.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/deferred_feature_screen.dart';
import '../../common/top_level_page.dart';
import '../data/products_repository.dart';

/// PR-01 Product list: search, status chips, rows with stock state.
class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  void _addProduct(BuildContext context) =>
      showAppSnackBar(context, context.l10n.addProductUnavailable);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final list = ref.watch(productListProvider);
    final query = ref.watch(productQueryProvider);
    final queryCtl = ref.read(productQueryProvider.notifier);

    final Widget body = switch (list) {
      AsyncData(:final value) when value.items.isEmpty => EmptyState(
        icon: AppIcons.package,
        title: l10n.productsEmptyTitle,
        body: l10n.productsEmptyBody,
        action: AppButton(
          label: l10n.addProduct,
          icon: AppIcons.plus,
          onPressed: () => _addProduct(context),
        ),
      ),
      AsyncData(:final value) => _ProductResults(list: value, query: query),
      AsyncError() => ErrorState(
        cause: l10n.errorServer,
        onRetry: () => ref.invalidate(productListProvider),
      ),
      _ => const _ProductsSkeleton(),
    };

    final hasItems = list.value?.items.isNotEmpty ?? false;
    return TopLevelPage(
      title: l10n.productsTitle,
      floatingActionButton: hasItems && !WindowClass.of(context).usesRail
          ? FloatingActionButton.extended(
              onPressed: () => _addProduct(context),
              backgroundColor: context.palette.brandPrimary,
              foregroundColor: context.palette.textOnBrand,
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              icon: const Icon(AppIcons.plus, size: Sizes.iconMd),
              label: Text(
                l10n.addProduct,
                style: context.type.button.copyWith(
                  color: context.palette.textOnBrand,
                ),
              ),
            )
          : null,
      slivers: [
        if (hasItems)
          SliverToBoxAdapter(
            child: ContentWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (list.value!.isSample) ...[
                    const SampleDataBanner(),
                    const SizedBox(height: Space.s16),
                  ],
                  AppSearchField(
                    hint: l10n.searchProductsHint,
                    clearTooltip: MaterialLocalizations.of(context)
                        .clearButtonTooltip,
                    onChanged: queryCtl.setText,
                  ),
                  const SizedBox(height: Space.s8),
                  FilterChipRow<ProductFilter>(
                    options: [
                      (ProductFilter.all, l10n.filterAll),
                      (ProductFilter.lowStock, l10n.filterLowStock),
                      (ProductFilter.outOfStock, l10n.filterOutOfStock),
                    ],
                    selected: query.filter,
                    onSelected: queryCtl.setFilter,
                  ),
                  const SizedBox(height: Space.s8),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: ContentWidth(
            child: AnimatedSwitcher(duration: MotionTokens.sm, child: body),
          ),
        ),
      ],
    );
  }
}

class _ProductResults extends ConsumerWidget {
  const _ProductResults({required this.list, required this.query});

  final ProductList list;
  final ProductQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final items = list.items.where(query.matches).toList();
    if (items.isEmpty) {
      return EmptyState(
        icon: AppIcons.magnifyingGlass,
        title: query.text.isNotEmpty
            ? l10n.noResultsFor(Bidi.auto(query.text))
            : l10n.noResultsFilters,
        action: AppButton(
          label: l10n.clearFilters,
          variant: AppButtonVariant.secondary,
          onPressed: () => ref.read(productQueryProvider.notifier).clear(),
        ),
      );
    }
    return RowGroup(
      key: ValueKey('${query.text}|${query.filter}'),
      children: [
        for (final p in items) _ProductRow(product: p, currency: list.currency),
      ],
    );
  }
}

class _ProductRow extends ConsumerWidget {
  const _ProductRow({required this.product, required this.currency});

  final ProductSummary product;
  final Currency currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final locale = Localizations.localeOf(context);
    final price = product.priceMin == product.priceMax
        ? Money.format(
            product.priceMin,
            currency,
            locale: locale,
            digits: digits,
          )
        : '${Money.amount(product.priceMin, digits: digits)} – ${Money.format(product.priceMax, currency, locale: locale, digits: digits)}';
    final stockText = Digits.display('${product.stock}', digits);
    final (StockState state, String stockLabel) = product.isOut
        ? (StockState.out, l10n.stockOut)
        : product.isLow
        ? (StockState.low, l10n.stockLow(stockText))
        : (StockState.inStock, l10n.stockInStock(stockText));

    return Semantics(
      button: true,
      label: '${product.name}, $price, $stockLabel',
      excludeSemantics: true,
      child: InkWell(
        onTap: () =>
            context.push(Routes.later(DeferredFeature.productDetails.name)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.s12,
              vertical: Space.s8,
            ),
            child: Row(
              children: [
                const ProductThumbnail(),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textDirection: Bidi.detect(product.name),
                        style: type.bodyStrong.copyWith(color: p.textPrimary),
                      ),
                      const SizedBox(height: Space.s2),
                      Text(
                        '$price · ${l10n.variantCount(product.variantCount)}',
                        style: type.caption.copyWith(color: p.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.s8),
                StockIndicator(state: state, label: stockLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProductsSkeleton extends StatelessWidget {
  const _ProductsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: Column(
        children: [
          for (var i = 0; i < 6; i++)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.s8),
              child: Row(
                children: [
                  SkeletonBlock(
                    width: Sizes.thumbList,
                    height: Sizes.thumbList,
                  ),
                  SizedBox(width: Space.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBlock(height: 14),
                        SizedBox(height: Space.s8),
                        SkeletonBlock(width: 120, height: 10),
                      ],
                    ),
                  ),
                  SizedBox(width: Space.s12),
                  SkeletonBlock(width: 56, height: 10),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
