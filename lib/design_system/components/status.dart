import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../theme/theme_ext.dart';
import '../tokens/tokens.g.dart';
import 'pencil.dart';

/// Visual tone shared by badges, banners and captions.
enum Tone { neutral, info, success, warning, danger, pencil }

({Color fg, Color bg}) toneColors(BuildContext context, Tone tone) {
  final p = context.palette;
  return switch (tone) {
    Tone.neutral => (fg: p.neutralBadgeFg, bg: p.neutralBadgeBg),
    Tone.info => (fg: p.infoFg, bg: p.infoBg),
    Tone.success => (fg: p.successFg, bg: p.successBg),
    Tone.warning => (fg: p.warningFg, bg: p.warningBg),
    Tone.danger => (fg: p.dangerFgOnBg, bg: p.dangerBg),
    Tone.pencil => (fg: p.textPencil, bg: p.bgPencil),
  };
}

/// Status badge: always icon + text, never colour alone
/// (Phase 2 CMP-StatusBadge). The pencil tone draws a dashed outline.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    required this.icon,
    this.tone = Tone.neutral,
  });

  final String label;
  final IconData icon;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final c = toneColors(context, tone);
    final row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.s8,
        vertical: Space.s2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: Sizes.iconSm, color: c.fg),
          const SizedBox(width: Space.s4),
          Flexible(
            child: Text(label, style: context.type.label.copyWith(color: c.fg)),
          ),
        ],
      ),
    );
    final decorated = tone == Tone.pencil
        ? CustomPaint(
            painter: PencilBorderPainter(
              color: context.palette.borderPencil,
              radius: Radii.sm,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: c.bg,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: row,
            ),
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: row,
          );
    return Semantics(label: label, excludeSemantics: true, child: decorated);
  }
}

/// Stock state for indicators (Phase 2 §2.4).
enum StockState { inStock, low, out }

/// Stock indicator text + optional icon. In lists, "in stock" is calm
/// (secondary text); inside an order line it is success-coloured because it
/// answers "can I approve?" ([emphasizeAvailable]).
class StockIndicator extends StatelessWidget {
  const StockIndicator({
    super.key,
    required this.state,
    required this.label,
    this.emphasizeAvailable = false,
  });

  final StockState state;
  final String label;
  final bool emphasizeAvailable;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (Color color, IconData? icon) = switch (state) {
      StockState.inStock => (
        emphasizeAvailable ? p.successFg : p.textSecondary,
        null,
      ),
      StockState.low => (p.warningFg, AppIcons.trendDown),
      StockState.out => (p.dangerFg, AppIcons.prohibit),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: Sizes.iconSm, color: color),
          const SizedBox(width: Space.s4),
        ],
        Flexible(
          child: Text(
            label,
            style: context.type.caption.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// Where an AI-filled or committed value came from (Phase 2 §5.2).
enum Provenance { fromCustomer, catalog, settings, inferred, editedByYou }

/// Caption under a value naming its source, with icon.
class ProvenanceCaption extends StatelessWidget {
  const ProvenanceCaption({super.key, required this.kind, required this.label});

  final Provenance kind;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (IconData icon, Color color) = switch (kind) {
      Provenance.fromCustomer => (AppIcons.chatText, p.textTertiary),
      Provenance.catalog => (AppIcons.bookOpen, p.textTertiary),
      Provenance.settings => (AppIcons.gear, p.textTertiary),
      Provenance.inferred => (AppIcons.question, p.warningFg),
      Provenance.editedByYou => (AppIcons.userCircle, p.textTertiary),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: Space.s4),
        Flexible(
          child: Text(
            label,
            style: context.type.caption.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// A value the AI filled in: dotted pencil underline (Phase 2 §1.1).
class PencilUnderline extends StatelessWidget {
  const PencilUnderline({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DottedUnderlinePainter(context.palette.borderPencil),
      child: Padding(padding: const EdgeInsets.only(bottom: 3), child: child),
    );
  }
}

class _DottedUnderlinePainter extends CustomPainter {
  const _DottedUnderlinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = Strokes.pencil
      ..strokeCap = StrokeCap.round;
    for (var x = 1.0; x < size.width; x += 4) {
      canvas.drawPoints(PointMode.points, [Offset(x, size.height - 1)], paint);
    }
  }

  @override
  bool shouldRepaint(_DottedUnderlinePainter old) => old.color != color;
}
