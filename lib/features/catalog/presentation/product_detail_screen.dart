import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/backend/api.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../application/catalog_providers.dart';
import '../domain/catalog.dart';
import 'adjust_stock_sheet.dart';
import 'catalog_text.dart';
import 'catalog_widgets.dart';
import 'image_viewer_screen.dart';

/// PR-02 Product detail: photos, price, description, stock per variant with
/// Adjust, inventory history, Edit, and the status actions. Everything shown
/// comes from the server; after a change the product is re-read.
class ProductDetailScreen extends ConsumerWidget {
  const ProductDetailScreen({
    super.key,
    required this.productId,
    this.embedded = false,
  });

  final String productId;

  /// Shown as the detail pane of the tablet list–detail layout.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final product = ref.watch(productProvider(productId));
    final value = product.value;

    final Widget body = switch (product) {
      AsyncData(:final value) => _DetailBody(product: value),
      AsyncError(:final error) =>
        error is ApiException && error.code == ApiErrorCode.notFound
            ? EmptyState(
                icon: AppIcons.package,
                title: l10n.productUnavailableTitle,
                body: l10n.productUnavailableBody,
              )
            : ErrorState(
                cause: loadErrorText(l10n, error),
                onRetry: () => ref.invalidate(productProvider(productId)),
              ),
      _ => const Center(child: CircularProgressIndicator()),
    };

    return Scaffold(
      backgroundColor: p.bgCanvas,
      appBar: AppBar(
        automaticallyImplyLeading: !embedded,
        title: Text(
          value?.name ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textDirection: value == null ? null : Bidi.detect(value.name),
        ),
        actions: [
          if (value != null) ...[
            TextButton(
              onPressed: () => context.push(Routes.productEdit(value.id)),
              child: Text(l10n.edit),
            ),
            _StatusMenu(product: value),
          ],
        ],
      ),
      body: AnimatedSwitcher(
        duration: Motion.fade(context, MotionTokens.sm),
        child: KeyedSubtree(key: ValueKey(product.hasValue), child: body),
      ),
    );
  }
}

class _StatusMenu extends ConsumerWidget {
  const _StatusMenu({required this.product});

  final Product product;

  Future<void> _set(
    BuildContext context,
    WidgetRef ref,
    ProductStatus status,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    if (status == ProductStatus.archived) {
      final ok = await showConfirmDialog(
        context: context,
        title: l10n.archiveProductTitle(Bidi.auto(product.name)),
        body: l10n.archiveProductBody,
        confirmLabel: l10n.archiveProduct,
        cancelLabel: l10n.cancel,
        destructive: true,
      );
      if (!ok) return;
    }
    try {
      await ref.read(catalogActionsProvider).setStatus(product, status);
      showSnackOn(messenger, switch (status) {
        ProductStatus.archived => l10n.productArchived,
        ProductStatus.inactive => l10n.productNowInactive,
        ProductStatus.active =>
          product.status == ProductStatus.archived
              ? l10n.productRestored
              : l10n.productNowActive,
      });
    } on ApiException catch (e) {
      ref.invalidate(productProvider(product.id));
      showSnackOn(
        messenger,
        catalogErrorText(l10n, e, digits: ref.read(settingsProvider).digits),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final items = <(ProductStatus, String, IconData)>[
      if (product.status == ProductStatus.active)
        (ProductStatus.inactive, l10n.makeInactive, AppIcons.eyeSlash),
      if (product.status == ProductStatus.inactive)
        (ProductStatus.active, l10n.makeActive, AppIcons.eye),
      if (product.status != ProductStatus.archived)
        (ProductStatus.archived, l10n.archiveProduct, AppIcons.archive),
      if (product.status == ProductStatus.archived)
        (ProductStatus.active, l10n.restoreProduct, AppIcons.arrowUUpLeft),
    ];
    return PopupMenuButton<ProductStatus>(
      tooltip: l10n.moreActions,
      icon: const Icon(AppIcons.dotsThree),
      onSelected: (s) => _set(context, ref, s),
      itemBuilder: (_) => [
        for (final (status, label, icon) in items)
          PopupMenuItem(
            value: status,
            child: Row(
              children: [
                Icon(icon, size: Sizes.iconMd),
                const SizedBox(width: Space.s12),
                Text(label),
              ],
            ),
          ),
      ],
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final active = product.activeVariants;
    final archivedCount = product.variants.length - active.length;
    final prices = active.map((v) => v.price);
    final wide = WindowClass.of(context).index >= WindowClass.medium.index;

    final gallery = _Gallery(product: product);
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (product.status != ProductStatus.active) ...[
          AppBanner(
            tone: Tone.neutral,
            icon: product.status == ProductStatus.archived
                ? AppIcons.archive
                : AppIcons.eyeSlash,
            title: product.status == ProductStatus.archived
                ? l10n.archivedBanner
                : l10n.inactiveBanner,
          ),
          const SizedBox(height: Space.s16),
        ],
        Semantics(
          header: true,
          child: Text(
            Bidi.auto(product.name),
            style: type.title.copyWith(color: p.textPrimary),
          ),
        ),
        const SizedBox(height: Space.s4),
        Text(
          prices.isEmpty
              ? formatPrice(context, ref, product.basePrice)
              : formatPriceRange(
                  context,
                  ref,
                  prices.reduce((a, b) => a < b ? a : b),
                  prices.reduce((a, b) => a > b ? a : b),
                ),
          style: type.bodyStrong.copyWith(color: p.textPrimary),
        ),
        if (product.category != null) ...[
          const SizedBox(height: Space.s4),
          Text(
            Bidi.auto(product.category!),
            style: type.caption.copyWith(color: p.textSecondary),
          ),
        ],
        if (product.description != null) ...[
          const SizedBox(height: Space.s16),
          Text(
            Bidi.auto(product.description!),
            style: type.body.copyWith(color: p.textPrimary),
          ),
        ],
        const SizedBox(height: Space.s24),
        SectionHeader(l10n.sectionStock),
        if (!product.trackStock) ...[
          Text(
            l10n.stockNotTrackedNote,
            style: type.caption.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: Space.s8),
        ],
        RowGroup(
          children: [
            for (final v in active)
              _VariantStockRow(product: product, variant: v),
          ],
        ),
        if (product.trackStock) ...[
          const SizedBox(height: Space.s8),
          Text(
            l10n.lowStockAt(
              count(
                product.defaultVariant?.lowStockThreshold ??
                    product.lowStockDefault,
                digits,
              ),
            ),
            style: type.caption.copyWith(color: p.textSecondary),
          ),
        ],
        if (archivedCount > 0) ...[
          const SizedBox(height: Space.s4),
          Text(
            l10n.archivedOptions(archivedCount),
            style: type.caption.copyWith(color: p.textTertiary),
          ),
        ],
        const SizedBox(height: Space.s16),
        RowGroup(
          children: [
            NavRow(
              label: l10n.inventoryHistory,
              icon: AppIcons.clockCounterClockwise,
              onTap: () => context.push(Routes.productHistory(product.id)),
            ),
          ],
        ),
      ],
    );

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(productProvider(product.id));
        try {
          await ref.read(productProvider(product.id).future);
        } on Object {
          // Shown by the error state.
        }
      },
      child: ListView(
        padding: const EdgeInsets.only(bottom: Space.s32),
        children: [
          ContentWidth(
            maxWidth: LayoutTokens.maxWidthReading,
            child: wide
                ? Padding(
                    padding: const EdgeInsets.only(top: Space.s16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 5, child: gallery),
                        const SizedBox(width: Space.s24),
                        Expanded(flex: 7, child: info),
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: Space.s8),
                      gallery,
                      const SizedBox(height: Space.s16),
                      info,
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Gallery extends StatefulWidget {
  const _Gallery({required this.product});
  final Product product;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final images = widget.product.images;
    final p = context.palette;
    if (images.isEmpty) {
      // No photo yet: a compact neutral placeholder, not a page-wide box.
      return const Align(
        alignment: AlignmentDirectional.centerStart,
        child: ProductImage(path: null, size: 120, radius: Radii.lg),
      );
    }
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: PageView.builder(
            itemCount: images.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => Semantics(
              image: true,
              button: true,
              label: context.l10n.photoCount(i + 1, images.length),
              child: GestureDetector(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ImageViewerScreen(
                      paths: [for (final i in images) i.path],
                      initialIndex: i,
                    ),
                  ),
                ),
                child: ProductImage(
                  path: images[i].path,
                  size: null,
                  radius: Radii.lg,
                  showFailureCaption: true,
                ),
              ),
            ),
          ),
        ),
        if (images.length > 1) ...[
          const SizedBox(height: Space.s8),
          ExcludeSemantics(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < images.length; i++)
                  AnimatedContainer(
                    duration: Motion.fade(context, MotionTokens.sm),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page ? p.brandPrimary : p.borderControl,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _VariantStockRow extends ConsumerWidget {
  const _VariantStockRow({required this.product, required this.variant});

  final Product product;
  final Variant variant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final (state, label) = variantStock(context, product, variant, digits);
    final name = product.hasOptions ? variant.label : l10n.sectionStock;
    final sku = variant.sku;
    final canAdjust =
        product.trackStock && product.status != ProductStatus.archived;
    return Semantics(
      label: '$name, $label',
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.s12,
          vertical: Space.s8,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Text(
                      name,
                      textDirection: Bidi.detect(name),
                      style: type.body.copyWith(color: p.textPrimary),
                    ),
                  ),
                  if (sku != null)
                    Text(
                      '${l10n.fieldSku} ${Bidi.ltr(sku)}',
                      style: type.caption.copyWith(color: p.textTertiary),
                    ),
                  const SizedBox(height: Space.s2),
                  AnimatedSwitcher(
                    duration: Motion.fade(context, MotionTokens.sm),
                    child: ExcludeSemantics(
                      key: ValueKey(label),
                      child: StockIndicator(state: state, label: label),
                    ),
                  ),
                ],
              ),
            ),
            if (canAdjust)
              AppButton(
                label: l10n.adjust,
                variant: AppButtonVariant.secondary,
                onPressed: () => showAdjustStockSheet(
                  context,
                  product: product,
                  variant: variant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
