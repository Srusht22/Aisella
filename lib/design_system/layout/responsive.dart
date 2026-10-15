import 'package:flutter/widgets.dart';

import '../tokens/tokens.g.dart';

/// Window classes from available width (Phase 2 §4.2), never device models.
enum WindowClass {
  compactSmall,
  compact,
  medium,
  expanded,
  large;

  static WindowClass forSize(Size size) {
    final w = size.width;
    if (w >= LayoutTokens.breakpointLarge) return WindowClass.large;
    if (w >= LayoutTokens.breakpointExpanded) return WindowClass.expanded;
    if (w >= LayoutTokens.breakpointMedium) return WindowClass.medium;
    if (w <= LayoutTokens.compactSmallMaxWidth ||
        size.height <= LayoutTokens.compactSmallMaxHeight) {
      return WindowClass.compactSmall;
    }
    return WindowClass.compact;
  }

  static WindowClass of(BuildContext context) =>
      forSize(MediaQuery.sizeOf(context));

  bool get usesRail => index >= WindowClass.medium.index;
  bool get usesListDetail => index >= WindowClass.expanded.index;

  double get gutter => switch (this) {
    WindowClass.compactSmall => LayoutTokens.gutterCompactSmall,
    WindowClass.compact => LayoutTokens.gutterCompact,
    WindowClass.medium => LayoutTokens.gutterMedium,
    WindowClass.expanded => LayoutTokens.gutterExpanded,
    WindowClass.large => LayoutTokens.gutterLarge,
  };
}

/// Centres content and caps its width so phone layouts never simply stretch
/// across tablets; applies the window-class gutter.
class ContentWidth extends StatelessWidget {
  const ContentWidth({
    super.key,
    required this.child,
    this.maxWidth = LayoutTokens.maxWidthReading,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final gutter = WindowClass.of(context).gutter;
    return Align(
      alignment: AlignmentDirectional.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth + 2 * gutter),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: gutter),
          child: child,
        ),
      ),
    );
  }
}
