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

  /// Distance from the start edge of an [available]-wide area to where the
  /// content column begins, so headers outside the column can align to it.
  static double startInset(
    double available, {
    required double gutter,
    double maxWidth = LayoutTokens.maxWidthReading,
  }) {
    final box = available.clamp(0.0, maxWidth + 2 * gutter);
    return (available - box) / 2 + gutter;
  }

  @override
  Widget build(BuildContext context) {
    final gutter = WindowClass.of(context).gutter;
    // Fills the column width (children start-align) up to [maxWidth],
    // and centres the column on wider windows.
    return Align(
      alignment: AlignmentDirectional.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth + 2 * gutter),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: child,
          ),
        ),
      ),
    );
  }
}
