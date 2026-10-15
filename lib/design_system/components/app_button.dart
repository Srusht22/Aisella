import 'package:flutter/material.dart';

import '../motion/primitives.dart';
import '../theme/theme_ext.dart';
import '../tokens/tokens.g.dart';

/// Button variants (Phase 2 CMP-Button).
enum AppButtonVariant {
  primary,
  secondary,
  tertiary,
  dangerOutline,
  danger,
  warning,
}

/// Aisellia button. Disabled when [onPressed] is null. While [loading] the
/// label is replaced by [loadingLabel] plus a spinner, the width is locked and
/// taps are ignored. There is deliberately no "success" state: outcomes are
/// shown on the record, not on the button (Phase 2 §05 §1).
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.loading = false,
    this.loadingLabel,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final IconData? icon;
  final bool loading;
  final String? loadingLabel;
  final bool expand;

  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    final (Color bg, Color fg, Color? outline) = switch (variant) {
      AppButtonVariant.primary => (p.brandPrimary, p.textOnBrand, null),
      AppButtonVariant.secondary => (
        p.bgSurface,
        p.textPrimary,
        p.borderControl,
      ),
      AppButtonVariant.tertiary => (const Color(0x00000000), p.textBrand, null),
      AppButtonVariant.dangerOutline => (
        p.bgSurface,
        p.dangerFg,
        p.borderHairline,
      ),
      AppButtonVariant.danger => (p.dangerFg, p.dangerOnFill, null),
      AppButtonVariant.warning => (p.bgSurface, p.warningFg, p.warningFg),
    };
    final disabledPrimary =
        !_enabled &&
        !loading &&
        (variant == AppButtonVariant.primary ||
            variant == AppButtonVariant.danger);
    final labelColor = _enabled || loading
        ? fg
        : (disabledPrimary ? fg : p.textDisabled);

    Widget content(String text, {bool spinner = false}) => Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (spinner) ...[
          SizedBox.square(
            dimension: Sizes.iconSm,
            child: CircularProgressIndicator(strokeWidth: 2, color: labelColor),
          ),
          const SizedBox(width: Space.s8),
        ] else if (icon != null) ...[
          Icon(icon, size: Sizes.iconMd, color: labelColor),
          const SizedBox(width: Space.s8),
        ],
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: type.button.copyWith(color: labelColor),
          ),
        ),
      ],
    );

    final body = loading
        ? Stack(
            alignment: Alignment.center,
            children: [
              // Keeps the original width so the button does not jump.
              Opacity(opacity: 0, child: content(label)),
              content(loadingLabel ?? label, spinner: true),
            ],
          )
        : content(label);

    final button = Semantics(
      button: true,
      enabled: _enabled,
      label: loading ? (loadingLabel ?? label) : label,
      excludeSemantics: true,
      child: Opacity(
        opacity: disabledPrimary ? 0.4 : 1,
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            side: outline == null
                ? BorderSide.none
                : BorderSide(color: outline, width: Strokes.control),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _enabled ? onPressed : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: LayoutTokens.minTouchTarget,
                minWidth: LayoutTokens.minTouchTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.s16,
                  vertical: Space.s12,
                ),
                child: Center(widthFactor: 1, child: body),
              ),
            ),
          ),
        ),
      ),
    );
    final pressable = PressScale(enabled: _enabled, child: button);
    return expand
        ? SizedBox(width: double.infinity, child: pressable)
        : pressable;
  }
}

/// 48 × 48 icon button with a required tooltip/semantics label
/// (Phase 2 CMP-IconButton).
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

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
            child: Icon(
              icon,
              size: Sizes.iconLg,
              color: onPressed == null ? p.textDisabled : p.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
