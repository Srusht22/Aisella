import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../theme/theme_ext.dart';
import '../tokens/tokens.g.dart';

/// Product image placeholder / thumbnail (Phase 2 §7). Real images arrive in
/// Phase 6; until then the neutral "missing image" state is shown, which
/// never looks like an error.
class ProductThumbnail extends StatelessWidget {
  const ProductThumbnail({super.key, this.size = Sizes.thumbList});

  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: p.bgSunken,
          borderRadius: BorderRadius.circular(Sizes.thumbRadius),
        ),
        child: Icon(AppIcons.package, size: size * 0.42, color: p.textTertiary),
      ),
    );
  }
}

/// Store button in top-level app bars (Phase 2 IA §1): initials on brand
/// weak, rounded square, opens the store menu.
class StoreButton extends StatelessWidget {
  const StoreButton({
    super.key,
    this.initials,
    required this.tooltip,
    required this.onPressed,
  });

  /// Store initials; shows a storefront icon when there is no store yet.
  final String? initials;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: InkResponse(
          onTap: onPressed,
          radius: LayoutTokens.minTouchTarget / 2,
          child: SizedBox.square(
            dimension: LayoutTokens.minTouchTarget,
            child: Center(
              child: Container(
                width: Sizes.storeLogo,
                height: Sizes.storeLogo,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p.bgBrandWeak,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: initials == null
                    ? Icon(
                        AppIcons.storefront,
                        size: Sizes.iconMd,
                        color: p.textBrand,
                      )
                    : Text(
                        initials!,
                        style: context.type.label.copyWith(
                          color: p.textBrand,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
