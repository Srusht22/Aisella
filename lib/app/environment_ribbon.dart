import 'package:flutter/material.dart';

import '../core/config/app_config.dart';
import '../core/l10n/l10n.dart';
import '../design_system/theme/theme_ext.dart';

/// Persistent corner ribbon on non-production builds so test data can never
/// be mistaken for a real store (Phase 3 deployment §3).
class EnvironmentRibbon extends StatelessWidget {
  const EnvironmentRibbon({
    super.key,
    required this.environment,
    required this.child,
  });

  final AppEnvironment environment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (environment == AppEnvironment.prod) return child;
    final p = context.palette;
    return Banner(
      message: context.l10n.envRibbon(environment.name.toUpperCase()),
      location: BannerLocation.topEnd,
      color: p.warningFg,
      textStyle: context.type.caption.copyWith(
        color: p.bgSurface,
        fontWeight: FontWeight.w600,
        fontSize: 9,
        height: 1,
      ),
      child: child,
    );
  }
}
