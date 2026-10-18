import 'package:flutter/widgets.dart';

import '../theme/theme_ext.dart';

/// The Aisellia mark: a bold geometric "A" with an AI spark in its
/// counter and a small one at its peak. Drawn, so it stays sharp at any
/// size and follows the colour theme. The same geometry is used for the app
/// icons (tool/icons/render_app_icon.py) and the web loading screen.
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
      child: CustomPaint(painter: _MarkPainter(ink: p.textOnBrand)),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter({required this.ink});

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 100;
    Offset p(double x, double y) => Offset(x * u, y * u);
    // The "A": two legs meeting at a rounded apex.
    final a = Path()
      ..moveTo(28 * u, 77 * u)
      ..lineTo(50 * u, 25 * u)
      ..lineTo(72 * u, 77 * u);
    canvas.drawPath(
      a,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 11 * u
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    // The spark in place of the crossbar, and a small one at the peak.
    canvas
      ..drawPath(_spark(p(50, 61), 8.5 * u), Paint()..color = ink)
      ..drawPath(_spark(p(73, 25), 5.5 * u), Paint()..color = ink);
  }

  /// A four-point star with gently pinched sides.
  static Path _spark(Offset c, double r) {
    final k = r * 0.22;
    return Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + k, c.dy - k, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + k, c.dy + k, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - k, c.dy + k, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - k, c.dy - k, c.dx, c.dy - r)
      ..close();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.ink != ink;
}
