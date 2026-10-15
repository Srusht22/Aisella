import 'package:flutter/widgets.dart';

import '../tokens/tokens.g.dart';

/// Publishes the effective reduced-motion preference: the OS setting OR the
/// in-app setting (Phase 2 §06 principle 6). Inserted once by the app root.
class MotionScope extends InheritedWidget {
  const MotionScope({super.key, required this.reduce, required super.child});

  final bool reduce;

  @override
  bool updateShouldNotify(MotionScope old) => old.reduce != reduce;
}

/// Motion helpers. Components ask here instead of reading tokens directly so
/// reduced motion is applied consistently.
abstract final class Motion {
  static bool reduced(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MotionScope>();
    final os = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return os || (scope?.reduce ?? false);
  }

  /// Duration for spatial motion (slides, scales, size). Zero when reduced.
  static Duration spatial(BuildContext context, Duration normal) =>
      reduced(context) ? Duration.zero : normal;

  /// Duration for fades. When reduced, spatial motion becomes a short
  /// crossfade (`motion.duration.sm`), never longer than the original.
  static Duration fade(BuildContext context, Duration normal) =>
      reduced(context) && normal > MotionTokens.sm ? MotionTokens.sm : normal;
}
