import 'dart:ui' show PathMetric;

import 'package:flutter/widgets.dart';

import '../motion/motion.dart';
import '../theme/theme_ext.dart';
import '../tokens/tokens.g.dart';

/// Paints the "pencil" outline (Phase 2 §1.1): a 1.5 px dashed rounded
/// rectangle (4 on, 3 off). [gap] animates to 0 for the ink settle.
class PencilBorderPainter extends CustomPainter {
  const PencilBorderPainter({
    required this.color,
    this.gap = Strokes.pencilGap,
    this.radius = Radii.md,
  });

  final Color color;
  final double gap;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = Strokes.pencil;
    const inset = Strokes.pencil / 2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        inset,
        inset,
        size.width - 2 * inset,
        size.height - 2 * inset,
      ),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    if (gap <= 0.01) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final PathMetric metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + Strokes.pencilDash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(PencilBorderPainter old) =>
      old.color != color || old.gap != gap || old.radius != radius;
}

/// A container drawn in pencil (AI proposal, not committed). When [settled]
/// becomes true the dashes close into a solid ink outline and the sheet
/// colour changes — the "ink settle" (Phase 2 §06 §4.1).
///
/// Only set [settled] after the server has confirmed the operation; this
/// widget never decides that anything succeeded.
class PencilBox extends StatelessWidget {
  const PencilBox({
    super.key,
    required this.child,
    this.settled = false,
    this.padding = const EdgeInsets.all(Space.s12),
  });

  final Widget child;
  final bool settled;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final duration = Motion.reduced(context)
        ? Motion.fade(context, MotionTokens.sm)
        : MotionTokens.lg;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: settled ? 1 : 0),
      duration: duration,
      curve: MotionTokens.enter,
      child: Padding(padding: padding, child: child),
      builder: (context, t, child) {
        final border = Color.lerp(p.borderPencil, p.borderFocus, t)!;
        return CustomPaint(
          painter: PencilBorderPainter(
            color: border,
            gap: Strokes.pencilGap * (1 - t),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color.lerp(p.bgPencil, p.bgBrandWeak, t),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: child,
          ),
        );
      },
    );
  }
}
