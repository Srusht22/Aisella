import 'package:flutter/material.dart';

import '../core/config/app_config.dart';
import '../core/l10n/l10n.dart';
import '../design_system/theme/theme_ext.dart';
import '../design_system/tokens/tokens.g.dart';

/// Persistent environment label on non-production builds so test data can
/// never be mistaken for a real store (Phase 3 deployment §3).
///
/// A small pill at the top centre, in the strip above the toolbar title.
/// A corner ribbon covered the store button and back button (visual
/// review). It ignores pointers, so it never blocks a tap.
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
    final top = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        child,
        PositionedDirectional(
          top: top,
          start: 0,
          end: 0,
          child: IgnorePointer(
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.warningFg,
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(Radii.sm),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.s8,
                    vertical: Space.s2,
                  ),
                  child: Text(
                    [
                      context.l10n.envRibbon(environment.name.toUpperCase()),
                      if (_buildSha.isNotEmpty) _buildSha,
                    ].join(' · '),
                    textScaler: TextScaler.noScaling,
                    style: context.type.caption.copyWith(
                      color: p.bgSurface,
                      fontWeight: FontWeight.w600,
                      fontSize: 10,
                      height: 1.2,
                      // Sits above the Navigator, outside any Material, so
                      // the debug "missing Material" underline must be off.
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Short commit of the build, set by the web build script, so testers can
/// tell which version a deployment serves. Empty in local builds and tests.
const _buildSha = String.fromEnvironment('BUILD_SHA');
