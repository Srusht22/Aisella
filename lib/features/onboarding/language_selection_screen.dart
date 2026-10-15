import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/l10n/supported_locales.dart';
import '../../core/settings/app_settings.dart';
import '../../design_system/components/app_button.dart';
import '../../design_system/components/inputs.dart';
import '../../design_system/components/rows.dart';
import '../../design_system/layout/responsive.dart';
import '../../design_system/motion/motion.dart';
import '../../design_system/theme/app_theme.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../../l10n/gen/app_localizations.dart';

/// Native language names; never translated.
const kLanguageNames = {'ckb': 'کوردی (سۆرانی)', 'en': 'English'};

/// AU-01: first-launch language choice. The layout direction previews the
/// selection immediately (RTL for Sorani) before Continue; the choice
/// persists across restarts.
class LanguageSelectionScreen extends ConsumerStatefulWidget {
  const LanguageSelectionScreen({super.key});

  @override
  ConsumerState<LanguageSelectionScreen> createState() =>
      _LanguageSelectionScreenState();
}

class _LanguageSelectionScreenState
    extends ConsumerState<LanguageSelectionScreen> {
  Locale? _pending;

  @override
  Widget build(BuildContext context) {
    final pending = _pending ?? Localizations.localeOf(context);
    final brightness = Theme.of(context).brightness;
    return AnimatedSwitcher(
      duration: Motion.fade(context, MotionTokens.md),
      child: Localizations.override(
        key: ValueKey(pending.languageCode),
        context: context,
        locale: pending,
        child: Theme(
          data: buildAppTheme(brightness: brightness, locale: pending),
          child: Builder(builder: (context) => _body(context, pending)),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Locale pending) {
    final p = context.palette;
    final type = context.type;
    final en = lookupAppLocalizations(SupportedLocales.en);
    final ckb = lookupAppLocalizations(SupportedLocales.ckb);
    return Scaffold(
      backgroundColor: p.bgCanvas,
      body: SafeArea(
        child: SingleChildScrollView(
          child: ContentWidth(
            maxWidth: LayoutTokens.maxWidthForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.s48),
                Text(
                  'aisellia',
                  style: type.titleLarge.copyWith(
                    color: p.brandPrimary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.24,
                  ),
                ),
                const SizedBox(height: Space.s24),
                // Shown in both languages: the user may not read the current one.
                Semantics(
                  header: true,
                  child: Text(
                    ckb.chooseLanguageTitle,
                    textDirection: TextDirection.rtl,
                    style: type.title.copyWith(color: p.textPrimary),
                  ),
                ),
                Text(
                  en.chooseLanguageTitle,
                  textDirection: TextDirection.ltr,
                  style: type.title.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: Space.s24),
                RowGroup(
                  children: [
                    for (final locale in SupportedLocales.all)
                      SelectionRow(
                        label: kLanguageNames[locale.languageCode]!,
                        labelDirection: SupportedLocales.isRtl(locale)
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        selected: pending == locale,
                        onTap: () => setState(() => _pending = locale),
                      ),
                  ],
                ),
                const SizedBox(height: Space.s8),
                Text(
                  context.l10n.chooseLanguageBody,
                  style: type.caption.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: Space.s32),
                AppButton(
                  label: context.l10n.continueAction,
                  expand: true,
                  onPressed: () =>
                      ref.read(settingsProvider.notifier).setLocale(pending),
                ),
                const SizedBox(height: Space.s24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
