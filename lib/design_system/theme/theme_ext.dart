import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';

import '../tokens/tokens.g.dart';
import 'typography.dart';

/// Convenience accessors used by every component and screen, so colours and
/// type always come from the active theme rather than literals.
extension AppThemeContext on BuildContext {
  AiselliaPalette get palette => Theme.of(this).extension<AiselliaPalette>()!;
  AppTypography get type => Theme.of(this).extension<AppTypography>()!;
}
