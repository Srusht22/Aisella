import 'package:flutter/widgets.dart';

import '../tokens/tokens.g.dart';
import 'motion.dart';

/// Subtle press feedback: scale 1 → 0.98 (Phase 2 §06 §5). Pure visual; the
/// wrapped control owns the tap. Scale is dropped under reduced motion.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  void _set(bool v) {
    if (widget.enabled && _pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _pressed && !reduced ? 0.98 : 1,
        duration: _pressed ? MotionTokens.xs : MotionTokens.sm,
        curve: MotionTokens.standard,
        child: widget.child,
      ),
    );
  }
}

/// Fades and slides content in from the top edge by 8 dp (banners, inline
/// errors). Under reduced motion it only fades.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MotionTokens.sm,
      curve: MotionTokens.enter,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(
            0,
            reduced ? 0 : -MotionTokens.distanceSmall * (1 - t),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Expand/collapse for inline sections (Phase 2 §06 §6): size `md`, content
/// fade `sm`. Instant size change under reduced motion.
class ExpandSection extends StatelessWidget {
  const ExpandSection({super.key, required this.expanded, required this.child});

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: Motion.spatial(context, MotionTokens.md),
      curve: MotionTokens.standard,
      alignment: AlignmentDirectional.topStart,
      child: AnimatedSwitcher(
        duration: Motion.fade(context, MotionTokens.sm),
        child: expanded
            ? KeyedSubtree(key: const ValueKey(true), child: child)
            : const SizedBox(key: ValueKey(false), width: double.infinity),
      ),
    );
  }
}

/// Animates a changing numeric label (stock, counts): changed values slide
/// vertically with a fade, up for increases and down for decreases.
/// Long values (> 6 digits) crossfade; reduced motion changes instantly
/// (Phase 2 §06 §4.2). Pass pre-formatted text in a tabular style.
class NumberRoll extends StatefulWidget {
  const NumberRoll({
    super.key,
    required this.value,
    required this.text,
    this.style,
  });

  /// Used only to pick the direction of travel.
  final num value;
  final String text;
  final TextStyle? style;

  @override
  State<NumberRoll> createState() => _NumberRollState();
}

class _NumberRollState extends State<NumberRoll> {
  double _direction = 1;

  @override
  void didUpdateWidget(NumberRoll old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _direction = widget.value > old.value ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion: swap instantly, with no outgoing child left in the
    // tree for a frame.
    if (Motion.reduced(context)) {
      return Text(widget.text, key: ValueKey(widget.text), style: widget.style);
    }
    final crossfadeOnly = widget.text.replaceAll(RegExp(r'\D'), '').length > 6;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: MotionTokens.numberRoll,
        switchInCurve: MotionTokens.enter,
        switchOutCurve: MotionTokens.exit,
        transitionBuilder: (child, animation) {
          if (crossfadeOnly) {
            return FadeTransition(opacity: animation, child: child);
          }
          final incoming = child.key == ValueKey(widget.text);
          final dy = 0.6 * _direction;
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(
                begin: Offset(0, incoming ? dy : -dy),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: Text(
          widget.text,
          key: ValueKey(widget.text),
          style: widget.style,
        ),
      ),
    );
  }
}
