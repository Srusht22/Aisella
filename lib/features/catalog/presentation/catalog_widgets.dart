import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/formatting/money.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../store/application/workspace_controller.dart';
import '../application/catalog_providers.dart';
import '../domain/catalog.dart';

/// The store's currency (one per store, BR-12).
Currency storeCurrency(WidgetRef ref) =>
    ref.watch(workspaceProvider.select((w) => w.value?.store?.currency)) ??
    Currency.iqd;

String formatPrice(BuildContext context, WidgetRef ref, int amount) =>
    Money.format(
      amount,
      storeCurrency(ref),
      locale: Localizations.localeOf(context),
      digits: ref.watch(settingsProvider).digits,
    );

/// "35,000 IQD" or a range "35,000 IQD – 42,000 IQD"; each amount is its own
/// LTR isolate with a localised separator (Phase 2 PR-01 #17).
String formatPriceRange(
  BuildContext context,
  WidgetRef ref,
  int min,
  int max,
) => min == max
    ? formatPrice(context, ref, min)
    : context.l10n.priceRange(
        formatPrice(context, ref, min),
        formatPrice(context, ref, max),
      );

/// Stock indicator text for a list row (Phase 2 §2.4, PR-01 #9).
(StockState, String) summaryStock(
  BuildContext context,
  ProductSummary p,
  DigitStyle digits,
) {
  final l10n = context.l10n;
  String n(int v) => Bidi.ltr(Digits.display('$v', digits));
  return switch (p.stockStatus) {
    StockStatus.available => (StockState.inStock, l10n.stockAvailable),
    StockStatus.unavailable => (StockState.out, l10n.stockUnavailable),
    StockStatus.out => (StockState.out, l10n.stockOut),
    StockStatus.low when p.variantCount > 1 => (
      StockState.low,
      l10n.optionsLow(p.lowCount),
    ),
    StockStatus.low => (StockState.low, l10n.stockLow(n(p.stockTotal))),
    StockStatus.inStock => (
      StockState.inStock,
      l10n.stockInStock(n(p.stockTotal)),
    ),
  };
}

/// Stock indicator text for one variant.
(StockState, String) variantStock(
  BuildContext context,
  Product product,
  Variant v,
  DigitStyle digits,
) {
  final l10n = context.l10n;
  final n = Bidi.ltr(Digits.display('${v.stockOnHand}', digits));
  return switch (product.statusOf(v)) {
    StockStatus.available => (StockState.inStock, l10n.stockAvailable),
    StockStatus.unavailable => (StockState.out, l10n.stockUnavailable),
    StockStatus.out => (StockState.out, l10n.stockOut),
    StockStatus.low => (StockState.low, l10n.stockLow(n)),
    StockStatus.inStock => (StockState.inStock, l10n.stockInStock(n)),
  };
}

/// Badge for inactive or archived products; nothing for active ones.
class ProductStatusBadge extends StatelessWidget {
  const ProductStatusBadge(this.status, {super.key});
  final ProductStatus status;

  @override
  Widget build(BuildContext context) => switch (status) {
    ProductStatus.active => const SizedBox.shrink(),
    ProductStatus.inactive => StatusBadge(
      label: context.l10n.statusInactive,
      icon: AppIcons.eyeSlash,
    ),
    ProductStatus.archived => StatusBadge(
      label: context.l10n.statusArchived,
      icon: AppIcons.archive,
    ),
  };
}

/// A product image from storage (Phase 2 §7): flat sunken box while loading,
/// then a fade-in; the neutral `Package` placeholder when there is no image;
/// the same placeholder with a small broken-image mark when it fails to load.
class ProductImage extends ConsumerWidget {
  const ProductImage({
    super.key,
    required this.path,
    this.size = Sizes.thumbList,
    this.radius = Sizes.thumbRadius,
    this.showFailureCaption = false,
  });

  final String? path;

  /// Square edge; null fills the parent (gallery).
  final double? size;
  final double radius;

  /// Detail view: "Image unavailable" under the mark.
  final bool showFailureCaption;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    Widget box(Widget? child) => ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        color: p.bgSunken,
        alignment: Alignment.center,
        child: child,
      ),
    );
    Widget placeholder({bool broken = false}) => box(
      LayoutBuilder(
        builder: (context, c) {
          final edge = c.biggest.shortestSide.isFinite
              ? c.biggest.shortestSide
              : (size ?? 56);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                broken ? AppIcons.imageBroken : AppIcons.package,
                size: (edge * 0.42).clamp(16, 48),
                color: p.textTertiary,
              ),
              if (broken && showFailureCaption) ...[
                const SizedBox(height: Space.s4),
                Text(
                  context.l10n.photoUnavailable,
                  style: context.type.caption.copyWith(color: p.textTertiary),
                ),
              ],
            ],
          );
        },
      ),
    );

    final path = this.path;
    if (path == null) return ExcludeSemantics(child: placeholder());
    final image = ref.watch(productImageProvider(path));
    return ExcludeSemantics(
      child: switch (image) {
        AsyncData(:final value) => box(
          Image(
            image: value,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, sync) => sync
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: Motion.fade(context, MotionTokens.sm),
                    child: child,
                  ),
            errorBuilder: (_, _, _) => placeholder(broken: true),
          ),
        ),
        AsyncError() => placeholder(broken: true),
        _ => box(null),
      },
    );
  }
}
