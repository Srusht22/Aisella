import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/primitives.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/top_level_page.dart';
import '../application/catalog_providers.dart';
import '../domain/catalog.dart';
import 'catalog_text.dart';
import 'catalog_widgets.dart';
import 'product_detail_screen.dart';

/// The product selected in the tablet list–detail layout (Phase 2 PR-01:
/// "Expanded: list–detail").
final selectedProductProvider = NotifierProvider<SelectedProduct, String?>(
  SelectedProduct.new,
);

class SelectedProduct extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(currentStoreIdProvider);
    return null;
  }

  void select(String? id) => state = id;
}

void openNewProduct(BuildContext context) => context.push(Routes.productNew);

/// PR-01 Product list: search (name, category, options, SKU), status chips,
/// category and sort, incremental loading. Every request is scoped to the
/// seller's store on the server.
class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windowClass = WindowClass.of(context);
    final list = _ProductList(listDetail: windowClass.usesListDetail);
    if (!windowClass.usesListDetail) return list;
    final selected = ref.watch(selectedProductProvider);
    final p = context.palette;
    return Row(
      children: [
        SizedBox(width: 420, child: list),
        VerticalDivider(width: Strokes.hairline, color: p.borderHairline),
        Expanded(
          child: selected == null
              ? ColoredBox(
                  color: p.bgCanvas,
                  child: Center(
                    child: EmptyState(
                      icon: AppIcons.package,
                      title: context.l10n.selectProductHint,
                    ),
                  ),
                )
              : ProductDetailScreen(
                  key: ValueKey(selected),
                  productId: selected,
                  embedded: true,
                ),
        ),
      ],
    );
  }
}

class _ProductList extends ConsumerWidget {
  const _ProductList({required this.listDetail});

  final bool listDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final list = ref.watch(catalogListProvider);
    final summary = ref.watch(catalogSummaryProvider).value;
    final query = ref.watch(catalogQueryProvider);
    final queryCtl = ref.read(catalogQueryProvider.notifier);
    final digits = ref.watch(settingsProvider).digits;
    // The catalog is empty only when the store has no product at all;
    // otherwise an empty page is "no results" for the current query.
    final catalogEmpty = summary != null && summary.total == 0;

    final Widget body = switch (list) {
      _ when catalogEmpty => EmptyState(
        icon: AppIcons.package,
        title: l10n.productsEmptyTitle,
        body: l10n.productsEmptyBody,
        action: AppButton(
          label: l10n.addProduct,
          icon: AppIcons.plus,
          onPressed: () => openNewProduct(context),
        ),
      ),
      AsyncData(:final value) when value.items.isEmpty => EmptyState(
        icon: AppIcons.magnifyingGlass,
        title: query.text.isNotEmpty
            ? l10n.noResultsFor(Bidi.auto(query.text))
            : l10n.noResultsFilters,
        action: AppButton(
          label: l10n.clearFilters,
          variant: AppButtonVariant.secondary,
          onPressed: queryCtl.clear,
        ),
      ),
      AsyncData(:final value) => _Results(state: value, listDetail: listDetail),
      AsyncError(:final error) => ErrorState(
        cause: loadErrorText(l10n, error),
        onRetry: () => ref.invalidate(catalogListProvider),
      ),
      _ => const _ProductsSkeleton(),
    };

    Widget chip(CatalogFilter f, String label, int? n) => Padding(
      padding: const EdgeInsetsDirectional.only(end: Space.s8),
      child: ChoiceChip(
        label: Text(
          n == null || n == 0
              ? label
              : '$label · ${Bidi.ltr(Digits.display('$n', digits))}',
        ),
        selected: query.filter == f,
        showCheckmark: false,
        onSelected: (_) => queryCtl.setFilter(f),
      ),
    );
    final refined = query.category != null || query.sort != CatalogSort.updated;

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 600) {
          ref.read(catalogListProvider.notifier).loadMore();
        }
        return false;
      },
      child: TopLevelPage(
        title: l10n.productsTitle,
        subtitle: list.value == null || catalogEmpty
            ? null
            : l10n.productsCount(list.value!.total),
        onRefresh: () async {
          ref.invalidate(catalogSummaryProvider);
          ref.invalidate(catalogListProvider);
          try {
            await ref.read(catalogListProvider.future);
          } on Object {
            // The list shows the error state with Retry.
          }
        },
        floatingActionButton: catalogEmpty || WindowClass.of(context).usesRail
            ? null
            : FloatingActionButton.extended(
                onPressed: () => openNewProduct(context),
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
              ),
        slivers: [
          if (!catalogEmpty)
            SliverToBoxAdapter(
              child: ContentWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (WindowClass.of(context).usesRail) ...[
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: AppButton(
                          label: l10n.addProduct,
                          icon: AppIcons.plus,
                          onPressed: () => openNewProduct(context),
                        ),
                      ),
                      const SizedBox(height: Space.s12),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: AppSearchField(
                            hint: l10n.searchProductsHint,
                            clearTooltip: MaterialLocalizations.of(context)
                                .clearButtonTooltip,
                            onChanged: queryCtl.setText,
                          ),
                        ),
                        const SizedBox(width: Space.s8),
                        Badge(
                          isLabelVisible: refined,
                          smallSize: 8,
                          backgroundColor: context.palette.brandPrimary,
                          child: IconButton(
                            tooltip: l10n.filterAndSort,
                            icon: const Icon(AppIcons.funnelSimple),
                            onPressed: () => _showRefine(context, ref),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.s8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          chip(CatalogFilter.all, l10n.filterAll, null),
                          chip(
                            CatalogFilter.low,
                            l10n.filterLowStock,
                            summary?.low,
                          ),
                          chip(
                            CatalogFilter.out,
                            l10n.filterOutOfStock,
                            summary?.out,
                          ),
                          chip(
                            CatalogFilter.inactive,
                            l10n.filterInactive,
                            summary?.inactive,
                          ),
                          chip(
                            CatalogFilter.archived,
                            l10n.filterArchived,
                            summary?.archived,
                          ),
                        ],
                      ),
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
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.state, required this.listDetail});

  final CatalogListState state;
  final bool listDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final selected = listDetail ? ref.watch(selectedProductProvider) : null;
    return Column(
      key: ValueKey(state.query),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RowGroup(
          children: [
            for (final (i, p) in state.items.indexed)
              _ProductRow(
                key: ValueKey(p.id),
                product: p,
                selected: p.id == selected,
                animate: i < 12,
                onTap: () => listDetail
                    ? ref.read(selectedProductProvider.notifier).select(p.id)
                    : context.push(Routes.product(p.id)),
              ),
          ],
        ),
        if (state.loadingMore)
          const Padding(
            padding: EdgeInsets.all(Space.s16),
            child: Center(
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (state.moreFailed)
          Padding(
            padding: const EdgeInsets.all(Space.s8),
            child: Column(
              children: [
                Text(
                  l10n.loadMoreFailed,
                  style: context.type.caption.copyWith(
                    color: context.palette.textSecondary,
                  ),
                ),
                AppButton(
                  label: l10n.retry,
                  variant: AppButtonVariant.tertiary,
                  onPressed: () =>
                      ref.read(catalogListProvider.notifier).loadMore(),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ProductRow extends ConsumerWidget {
  const _ProductRow({
    super.key,
    required this.product,
    required this.onTap,
    this.selected = false,
    this.animate = false,
  });

  final ProductSummary product;
  final VoidCallback onTap;
  final bool selected;
  final bool animate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final price = formatPriceRange(
      context,
      ref,
      product.priceMin,
      product.priceMax,
    );
    final (state, stockLabel) = summaryStock(context, product, digits);
    final options = product.variantCount > 1
        ? ' · ${l10n.variantCount(product.variantCount)}'
        : '';
    final status = switch (product.status) {
      ProductStatus.inactive => ', ${l10n.statusInactive}',
      ProductStatus.archived => ', ${l10n.statusArchived}',
      ProductStatus.active => '',
    };

    final row = Semantics(
      button: true,
      selected: selected,
      label: '${product.name}, $price$options, $stockLabel$status',
      excludeSemantics: true,
      child: Material(
        color: selected ? p.bgBrandWeak : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.s12,
                vertical: Space.s8,
              ),
              child: Row(
                children: [
                  ProductImage(path: product.imagePath),
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
                          style: type.bodyStrong.copyWith(
                            color: product.status == ProductStatus.active
                                ? p.textPrimary
                                : p.textSecondary,
                          ),
                        ),
                        const SizedBox(height: Space.s2),
                        Text(
                          '$price$options',
                          maxLines: 2,
                          style: type.caption.copyWith(color: p.textSecondary),
                        ),
                        if (product.status != ProductStatus.active) ...[
                          const SizedBox(height: Space.s4),
                          ProductStatusBadge(product.status),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.s8),
                  // At the end of the row (PR-01); long labels wrap.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 132),
                    child: StockIndicator(state: state, label: stockLabel),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return animate ? FadeSlideIn(child: row) : row;
  }
}

Future<void> _showRefine(BuildContext context, WidgetRef ref) {
  final l10n = context.l10n;
  return showAppSheet<void>(
    context: context,
    title: l10n.filterAndSort,
    builder: (context) => Consumer(
      builder: (context, ref, _) {
        final query = ref.watch(catalogQueryProvider);
        final ctl = ref.read(catalogQueryProvider.notifier);
        final categories =
            ref.watch(catalogSummaryProvider).value?.categories ?? const [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SectionHeader(l10n.sortTitle),
            RowGroup(
              children: [
                for (final (sort, label) in [
                  (CatalogSort.updated, l10n.sortUpdated),
                  (CatalogSort.name, l10n.sortName),
                  (CatalogSort.priceAsc, l10n.sortPriceAsc),
                  (CatalogSort.priceDesc, l10n.sortPriceDesc),
                  (CatalogSort.stockAsc, l10n.sortStockAsc),
                ])
                  SelectionRow(
                    label: label,
                    selected: query.sort == sort,
                    onTap: () => ctl.setSort(sort),
                  ),
              ],
            ),
            if (categories.isNotEmpty) ...[
              const SizedBox(height: Space.s16),
              SectionHeader(l10n.fieldCategory),
              RowGroup(
                children: [
                  SelectionRow(
                    label: l10n.categoryAll,
                    selected: query.category == null,
                    onTap: () => ctl.setCategory(null),
                  ),
                  for (final c in categories)
                    SelectionRow(
                      label: c.name,
                      labelDirection: Bidi.detect(c.name),
                      selected:
                          query.category?.toLowerCase() == c.name.toLowerCase(),
                      onTap: () => ctl.setCategory(c.name),
                    ),
                ],
              ),
            ],
            const SizedBox(height: Space.s16),
            AppButton(
              label: l10n.showResults,
              expand: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    ),
  );
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
