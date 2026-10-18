import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/l10n/supported_locales.dart';
import '../../core/settings/app_settings.dart';
import '../../design_system/components/inputs.dart';
import '../../design_system/components/overlays.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../onboarding/language_selection_screen.dart' show kLanguageNames;
import 'appearance_picker.dart';

// Header controls shown on Welcome, sign-up/sign-in and the four tab roots.

/// Opens light/dark mode and the colour themes.
class AppearanceButton extends StatelessWidget {
  const AppearanceButton({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconButton(
      tooltip: context.l10n.appearanceTitle,
      // Palette icon (Freepik, Flaticon) in the theme's brand colour, so it
      // changes with every colour theme and stays visible in light and dark.
      icon: Image.asset(
        'assets/icons/palette.png',
        width: 22,
        height: 22,
        color: p.brandPrimary,
      ),
      style: IconButton.styleFrom(side: BorderSide(color: p.borderHairline)),
      onPressed: () => showAppearanceSheet(context),
    );
  }
}

/// Opens the language choice. The change applies at once and is
/// remembered, so a visitor can switch before signing up.
class LanguageButton extends ConsumerWidget {
  const LanguageButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final current = Localizations.localeOf(context);
    final p = context.palette;
    final type = context.type;
    return Tooltip(
      message: l10n.appLanguage,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.s4),
        child: Material(
          color: p.bgSurface,
          shape: StadiumBorder(side: BorderSide(color: p.borderHairline)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _open(context, ref, current),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.s12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Language icon (Freepik, Flaticon) in the text colour:
                    // dark in light mode, light in dark mode.
                    Image.asset(
                      'assets/icons/language.png',
                      width: 18,
                      height: 18,
                      color: p.textPrimary,
                    ),
                    const SizedBox(width: Space.s8),
                    Text(
                      _short[current.languageCode] ?? '',
                      style: type.label.copyWith(color: p.textPrimary),
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

  /// Short names for the pill; the sheet shows the full native names.
  static const _short = {'en': 'EN', 'ckb': 'کوردی', 'ar': 'عربي'};

  void _open(BuildContext context, WidgetRef ref, Locale current) {
    final l10n = context.l10n;
    showAppSheet<void>(
      context: context,
      title: l10n.appLanguage,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final l in SupportedLocales.all)
            SelectionRow(
              label: kLanguageNames[l.languageCode]!,
              labelDirection: SupportedLocales.isRtl(l)
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              selected: current.languageCode == l.languageCode,
              onTap: () {
                ref.read(settingsProvider.notifier).setLocale(l);
                Navigator.of(sheetContext).pop();
              },
            ),
        ],
      ),
    );
  }
}
