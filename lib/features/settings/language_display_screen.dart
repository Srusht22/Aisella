import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatting/dates.dart';
import '../../core/formatting/money.dart';
import '../../core/formatting/phone.dart';
import '../../core/l10n/l10n.dart';
import '../../core/l10n/supported_locales.dart';
import '../../core/settings/app_settings.dart';
import '../../design_system/components/inputs.dart';
import '../../design_system/components/rows.dart';
import '../../design_system/icons/app_icons.dart';
import '../../design_system/layout/responsive.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../common/appearance_picker.dart';
import '../onboarding/language_selection_screen.dart' show kLanguageNames;

/// ST-06 Language and display. Changes apply immediately (direction flips,
/// digits re-render) without losing navigation state.
class LanguageDisplayScreen extends ConsumerWidget {
  const LanguageDisplayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final settings = ref.watch(settingsProvider);
    final ctl = ref.read(settingsProvider.notifier);
    final locale = Localizations.localeOf(context);

    // Formatting preview with fictional values.
    final preview = [
      Money.format(
        1250000,
        Currency.iqd,
        locale: locale,
        digits: settings.digits,
      ),
      Dates.weekdayDayMonth(
        DateTime(2026, 10, 15),
        locale: locale,
        digits: settings.digits,
      ),
      PhoneNumbers.display('+9647501234567'),
    ].join('\n');

    return Scaffold(
      appBar: AppBar(title: Text(l10n.menuLanguageDisplay)),
      body: ListView(
        children: [
          ContentWidth(
            maxWidth: LayoutTokens.maxWidthForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.s8),
                SectionHeader(l10n.appLanguage),
                RowGroup(
                  children: [
                    for (final l in SupportedLocales.all)
                      SelectionRow(
                        label: kLanguageNames[l.languageCode]!,
                        labelDirection: SupportedLocales.isRtl(l)
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        selected: locale.languageCode == l.languageCode,
                        onTap: () => ctl.setLocale(l),
                      ),
                  ],
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.digitsTitle),
                AppSegmented<DigitStyle>(
                  options: [
                    (DigitStyle.western, '${l10n.digitsWestern} 123'),
                    (DigitStyle.eastern, '${l10n.digitsEastern} ١٢٣'),
                  ],
                  selected: settings.digits,
                  onChanged: ctl.setDigits,
                ),
                const SizedBox(height: Space.s4),
                Text(
                  l10n.digitsNote,
                  style: type.caption.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.themeTitle),
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
                RowGroup(
                  children: [
                    NavRow(
                      label: accentName(l10n, settings.accent),
                      icon: AppIcons.circleHalf,
                      onTap: () => showAppearanceSheet(context),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.motionTitle),
                AppSegmented<MotionPreference>(
                  options: [
                    (MotionPreference.system, l10n.motionSystem),
                    (MotionPreference.reduce, l10n.motionReduce),
                  ],
                  selected: settings.motion,
                  onChanged: ctl.setMotion,
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.previewLabel),
                RowGroup(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(Space.s12),
                      child: Text(
                        preview,
                        style: type.numericBody.copyWith(color: p.textPrimary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s32),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
