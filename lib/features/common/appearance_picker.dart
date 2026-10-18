import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/settings/app_settings.dart';
import '../../design_system/components/inputs.dart';
import '../../design_system/components/overlays.dart';
import '../../design_system/components/rows.dart';
import '../../design_system/icons/app_icons.dart';
import '../../design_system/motion/motion.dart';
import '../../design_system/motion/primitives.dart';
import '../../design_system/theme/accents.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';

String accentName(AppLocalizations l10n, AppAccent a) => switch (a) {
  AppAccent.ledger => l10n.accentLedger,
  AppAccent.gold => l10n.accentGold,
  AppAccent.emerald => l10n.accentEmerald,
  AppAccent.sapphire => l10n.accentSapphire,
  AppAccent.ruby => l10n.accentRuby,
  AppAccent.amethyst => l10n.accentAmethyst,
  AppAccent.rose => l10n.accentRose,
  AppAccent.teal => l10n.accentTeal,
  AppAccent.copper => l10n.accentCopper,
  AppAccent.onyx => l10n.accentOnyx,
};

/// Opens light/dark mode and the colour themes in a sheet. Choices apply at
/// once (the app cross-fades) and are remembered.
Future<void> showAppearanceSheet(BuildContext context) => showAppSheet<void>(
  context: context,
  title: context.l10n.appearanceTitle,
  builder: (_) => const AppearancePicker(),
);

/// Mode (system, light, dark) and the colour theme grid.
class AppearancePicker extends ConsumerWidget {
  const AppearancePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    final ctl = ref.read(settingsProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.modeTitle),
        AppSegmented<ThemePreference>(
          options: [
            (ThemePreference.system, l10n.themeSystem),
            (ThemePreference.light, l10n.themeLight),
            (ThemePreference.dark, l10n.themeDark),
          ],
          selected: settings.theme,
          onChanged: ctl.setTheme,
        ),
        const SizedBox(height: Space.s24),
        SectionHeader(l10n.accentTitle),
        AccentGrid(selected: settings.accent, onChanged: ctl.setAccent),
      ],
    );
  }
}

/// The colour themes as gradient tiles: three across on phones, four on
/// wider windows. The chosen tile gets a ring and a check that scale in.
class AccentGrid extends StatelessWidget {
  const AccentGrid({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final AppAccent selected;
  final ValueChanged<AppAccent> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 480 ? 4 : 3;
      const gap = Space.s12;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final (i, a) in AppAccent.values.indexed)
            SizedBox(
              width: width,
              child: _Stagger(
                index: i,
                child: _AccentTile(
                  accent: a,
                  selected: a == selected,
                  onTap: () => onChanged(a),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _AccentTile extends StatelessWidget {
  const _AccentTile({
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final AppAccent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    final seed = accentSeeds[accent]!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final duration = Motion.fade(context, MotionTokens.md);
    final name = accentName(context.l10n, accent);
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      excludeSemantics: true,
      child: PressScale(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: duration,
            curve: MotionTokens.standard,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.lg + 3),
              border: Border.all(
                color: selected ? p.brandPrimary : p.borderHairline,
                width: selected ? 2 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.lg),
              child: ColoredBox(
                color: p.bgSurface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: 1.35,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: AlignmentDirectional.topStart,
                            end: AlignmentDirectional.bottomEnd,
                            colors: [dark ? seed.dark : seed.light, seed.deep],
                          ),
                        ),
                        child: Align(
                          alignment: AlignmentDirectional.topEnd,
                          child: AnimatedScale(
                            scale: selected ? 1 : 0,
                            duration: Motion.spatial(context, MotionTokens.md),
                            curve: Curves.easeOutBack,
                            child: Container(
                              margin: const EdgeInsets.all(Space.s8),
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Color(0xFFFFFFFF),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                AppIcons.checkFill,
                                size: 14,
                                color: seed.light,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.s4,
                        vertical: Space.s8,
                      ),
                      child: Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.label.copyWith(
                          color: selected ? p.textPrimary : p.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiles fade and rise in one after another when the grid first shows.
class _Stagger extends StatelessWidget {
  const _Stagger({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return child;
    final delay = 30 * index;
    final total = 280 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: MotionTokens.enter),
      child: child,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - v)),
          child: child,
        ),
      ),
    );
  }
}
