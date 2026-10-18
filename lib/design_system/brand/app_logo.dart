import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/theme_ext.dart';

/// The Aisellia mark: a shopping bag with a check on it, selling made
/// simple and every order under control. Drawn, so it stays sharp at any
/// size and follows the colour theme. The same geometry is used for the
/// app icons (tool/icons/render_app_icon.py) and the web loading screen.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 40, this.color, this.glow = false});

  final double size;

  /// Tile colour; defaults to the theme's brand colour.
  final Color? color;

  /// Adds a soft brand-coloured shadow, for hero placements.
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bg = color ?? p.brandPrimary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          begin: Alignment.topLeft, // rtl-ok: light falls from the same side
          end: Alignment.bottomRight, // rtl-ok: in every language
          colors: [
            Color.lerp(bg, const Color(0xFFFFFFFF), 0.12)!,
            Color.lerp(bg, const Color(0xFF000000), 0.18)!,
          ],
        ),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: bg.withValues(alpha: 0.35),
                  blurRadius: size * 0.4,
                  offset: Offset(0, size * 0.12),
                ),
              ]
            : null,
      ),
      child: CustomPaint(
        painter: _BagCheckPainter(ink: p.textOnBrand, cut: bg),
      ),
    );
  }
}

class _BagCheckPainter extends CustomPainter {
  const _BagCheckPainter({required this.ink, required this.cut});

  final Color ink;
  final Color cut;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 100;
    Offset p(double x, double y) => Offset(x * u, y * u);
    // Slanted sides (wider at the bottom) read as a shopping bag; corners
    // are rounded by stroking the outline with a round join.
    final bag = Path()
      ..addPolygon([p(33, 41), p(67, 41), p(72, 77), p(28, 77)], true);
    canvas
      ..drawPath(bag, Paint()..color = ink)
      ..drawPath(
        bag,
        Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10 * u
          ..strokeJoin = StrokeJoin.round,
      );
    // Handle.
    final handle = Path()
      ..moveTo(40 * u, 40 * u)
      ..lineTo(40 * u, 35 * u)
      ..arcTo(
        Rect.fromLTRB(40 * u, 25 * u, 60 * u, 45 * u),
        math.pi,
        math.pi,
        false,
      )
      ..lineTo(60 * u, 40 * u);
    canvas.drawPath(
      handle,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5 * u
        ..strokeCap = StrokeCap.round,
    );
    // Check, cut into the bag in the tile colour.
    final check = Path()
      ..moveTo(39 * u, 60 * u)
      ..lineTo(47 * u, 68 * u)
      ..lineTo(62 * u, 53 * u);
    canvas.drawPath(
      check,
      Paint()
        ..color = cut
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6 * u
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_BagCheckPainter old) => old.ink != ink || old.cut != cut;
}

/// A line globe: the language control.
class GlobeGlyph extends StatelessWidget {
  const GlobeGlyph({super.key, this.size = 20, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GlobePainter(color));
}

class _GlobePainter extends CustomPainter {
  const _GlobePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    final r = s * 0.42;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.08
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, r, paint);
    // Meridian.
    canvas.drawOval(
      Rect.fromCenter(center: c, width: r * 0.95, height: r * 2),
      paint,
    );
    // Equator and one parallel each side.
    canvas.drawLine(c.translate(-r, 0), c.translate(r, 0), paint);
    final h = r * 0.55;
    final w = math.sqrt(r * r - h * h) * 0.92;
    canvas.drawLine(c.translate(-w, -h), c.translate(w, -h), paint);
    canvas.drawLine(c.translate(-w, h), c.translate(w, h), paint);
  }

  @override
  bool shouldRepaint(_GlobePainter old) => old.color != color;
}

/// The appearance control: a ring of the colour themes around a half-lit
/// disc (light and dark).
class AppearanceGlyph extends StatelessWidget {
  const AppearanceGlyph({
    super.key,
    this.size = 22,
    required this.colors,
    required this.light,
    required this.dark,
  });

  final double size;
  final List<Color> colors;
  final Color light;
  final Color dark;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _AppearancePainter(colors, light, dark),
  );
}

class _AppearancePainter extends CustomPainter {
  const _AppearancePainter(this.colors, this.light, this.dark);

  final List<Color> colors;
  final Color light;
  final Color dark;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    final ring = s * 0.14;
    final r = s / 2 - ring / 2;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ring
        ..shader = SweepGradient(colors: [...colors, colors.first])
            .createShader(Rect.fromCircle(center: c, radius: r)),
    );
    final inner = Rect.fromCircle(center: c, radius: r - ring * 0.9);
    canvas
      ..drawArc(inner, math.pi / 2, math.pi, true, Paint()..color = light)
      ..drawArc(inner, -math.pi / 2, math.pi, true, Paint()..color = dark);
  }

  @override
  bool shouldRepaint(_AppearancePainter old) =>
      old.light != light || old.dark != dark;
}
