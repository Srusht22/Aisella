import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../theme/theme_ext.dart';
import '../tokens/tokens.g.dart';

/// Section label above a row group (Phase 2 CMP-SectionHeader). Uppercased
/// only for Latin script.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                type.overlineText(text),
                style: type.overline.copyWith(
                  color: context.palette.textSecondary,
                ),
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// The default container for detail content: one surface, hairline border,
/// hairlines between rows (Phase 2 CMP-RowGroup). Not a card per fact.
class RowGroup extends StatelessWidget {
  const RowGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.bgSurface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.borderHairline, width: Strokes.hairline),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(height: Strokes.hairline, color: p.borderHairline),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Label/value row (Phase 2 CMP-FieldRow). Below 360 dp or at text scale
/// ≥ 1.3 the label stacks above the value.
class FieldRow extends StatelessWidget {
  const FieldRow({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.onTap,
    this.trailing,
    this.semanticsLabel,
  });

  final String label;
  final Widget value;
  final Widget? caption;
  final VoidCallback? onTap;
  final Widget? trailing;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final type = context.type;
    final p = context.palette;
    final stack =
        MediaQuery.sizeOf(context).width < 360 ||
        MediaQuery.textScalerOf(context).scale(10) >= 13;
    final labelText = Text(
      label,
      style: type.label.copyWith(color: p.textSecondary),
    );
    final valueBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        DefaultTextStyle.merge(
          style: type.body.copyWith(color: p.textPrimary),
          child: value,
        ),
        if (caption != null) ...[const SizedBox(height: Space.s2), caption!],
      ],
    );
    final content = stack
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              labelText,
              const SizedBox(height: Space.s4),
              valueBlock,
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: labelText,
                ),
              ),
              const SizedBox(width: Space.s12),
              Expanded(child: valueBlock),
            ],
          );
    return Semantics(
      label: semanticsLabel,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: LayoutTokens.rowMinHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.s12,
              vertical: Space.s12,
            ),
            child: Row(
              children: [
                Expanded(child: content),
                if (trailing != null) ...[
                  const SizedBox(width: Space.s8),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tappable navigation row with optional leading icon, trailing value and
/// chevron (attention rows, menu rows). The chevron mirrors in RTL.
class NavRow extends StatelessWidget {
  const NavRow({
    super.key,
    required this.label,
    this.icon,
    this.iconColor,
    this.trailing,
    this.onTap,
    this.semanticsLabel,
    this.labelColor,
  });

  final String label;
  final IconData? icon;
  final Color? iconColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? semanticsLabel;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return Semantics(
      button: onTap != null,
      label: semanticsLabel,
      excludeSemantics: semanticsLabel != null,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.s12,
              vertical: Space.s8,
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: Sizes.iconMd,
                    color: iconColor ?? p.textSecondary,
                  ),
                  const SizedBox(width: Space.s12),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: type.body.copyWith(
                      color: labelColor ?? p.textPrimary,
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: Space.s8),
                  trailing!,
                ],
                if (onTap != null) ...[
                  const SizedBox(width: Space.s4),
                  Icon(
                    AppIcons.caretRight,
                    size: Sizes.iconMd,
                    color: p.textTertiary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
