import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/route_guard.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/l10n/supported_locales.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/brand/app_logo.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/theme/accents.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/appearance_picker.dart';
import '../../onboarding/language_selection_screen.dart' show kLanguageNames;

/// Shared layout for sign-up and sign-in: a top bar (back, language), a hero
/// mark with the title and subtitle, and the form on a raised card. Every
/// part enters once, in sequence, then holds still; reduced motion shows the
/// final layout at once (Phase 2 §06).
class AuthPage extends StatefulWidget {
  const AuthPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.card,
    this.footer = const [],
  });

  final String title;
  final String subtitle;
  final IconData icon;

  /// The form, shown on the card. Each child enters a little after the
  /// previous one.
  final List<Widget> card;

  /// Below the card: links to the other auth screen and similar.
  final List<Widget> footer;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _t.value = 1;
    } else if (_t.value == 0 && !_t.isAnimating) {
      _t.forward();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final cardStep = 0.5 / (widget.card.length + 1);

    return Scaffold(
      backgroundColor: p.bgCanvas,
      body: Stack(
        children: [
          // A soft brand wash behind the hero; it fades in once.
          PositionedDirectional(
            top: -180,
            start: -120,
            child: FadeTransition(
              opacity: _t,
              child: Container(
                width: 420,
                height: 420,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      p.brandPrimary.withValues(alpha: 0.18),
                      p.brandPrimary.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                ContentWidth(
                  maxWidth: LayoutTokens.maxWidthForm,
                  child: SizedBox(
                    height: 56,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: MaterialLocalizations.of(context)
                              .backButtonTooltip,
                          icon: const Icon(AppIcons.arrowLeft),
                          onPressed: () => context.canPop()
                              ? context.pop()
                              : context.go(Routes.welcome),
                        ),
                        const Spacer(),
                        const AppearanceButton(),
                        const LanguageButton(),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.only(
                      top: Space.s8,
                      bottom: Space.s32 + insets,
                    ),
                    children: [
                      ContentWidth(
                        maxWidth: LayoutTokens.maxWidthForm,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _HeroMark(t: _t, icon: widget.icon),
                            const SizedBox(height: Space.s20),
                            Reveal(
                              t: _t,
                              begin: 0.12,
                              child: Semantics(
                                header: true,
                                child: Text(
                                  widget.title,
                                  style: type.titleLarge.copyWith(
                                    color: p.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: Space.s8),
                            Reveal(
                              t: _t,
                              begin: 0.18,
                              child: Text(
                                widget.subtitle,
                                style: type.bodyLarge.copyWith(
                                  color: p.textSecondary,
                                ),
                              ),
                            ),
                            const SizedBox(height: Space.s24),
                            Reveal(
                              t: _t,
                              begin: 0.26,
                              distance: 28,
                              child: _Card(
                                children: [
                                  for (var i = 0; i < widget.card.length; i++)
                                    Reveal(
                                      t: _t,
                                      begin: 0.34 + cardStep * i,
                                      child: widget.card[i],
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: Space.s16),
                            for (final f in widget.footer)
                              Reveal(t: _t, begin: 0.7, child: f),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades and lifts [child] in over the part of [t] that starts at [begin].
class Reveal extends StatelessWidget {
  const Reveal({
    super.key,
    required this.t,
    required this.begin,
    required this.child,
    this.length = 0.3,
    this.distance = 16,
  });

  final Animation<double> t;
  final double begin;
  final double length;
  final double distance;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: t,
    child: child,
    builder: (context, child) {
      final v = MotionTokens.enter.transform(
        ((t.value - begin) / length).clamp(0.0, 1.0),
      );
      return Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, distance * (1 - v)),
          child: child,
        ),
      );
    },
  );
}

/// The brand tile with a ring that expands and fades once, like ink
/// spreading.
class _HeroMark extends StatelessWidget {
  const _HeroMark({required this.t, required this.icon});

  final Animation<double> t;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: 72,
        height: 72,
        child: AnimatedBuilder(
          animation: t,
          builder: (context, _) {
            final pop = Curves.easeOutBack.transform(
              (t.value / 0.35).clamp(0.0, 1.0),
            );
            final ring = Curves.easeOut.transform(
              ((t.value - 0.15) / 0.6).clamp(0.0, 1.0),
            );
            return Stack(
              alignment: Alignment.center,
              children: [
                Opacity(
                  opacity: (1 - ring) * 0.5,
                  child: Container(
                    width: 56 + 16 * ring,
                    height: 56 + 16 * ring,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Radii.lg + 6),
                      border: Border.all(color: p.brandPrimary, width: 2),
                    ),
                  ),
                ),
                Transform.scale(
                  scale: 0.6 + 0.4 * pop,
                  child: Opacity(
                    opacity: pop.clamp(0.0, 1.0),
                    child: const AppLogo(size: 56, glow: true),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(Space.s20),
      decoration: BoxDecoration(
        color: p.bgSurface,
        borderRadius: BorderRadius.circular(Radii.lg + 4),
        border: Border.all(color: p.borderHairline),
        boxShadow: [
          BoxShadow(
            color: p.brandPrimary.withValues(alpha: 0.08),
            blurRadius: 32,
            spreadRadius: -6,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// Opens light/dark mode and the colour themes.
class AppearanceButton extends StatelessWidget {
  const AppearanceButton({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconButton(
      tooltip: context.l10n.appearanceTitle,
      icon: AppearanceGlyph(
        size: 24,
        colors: [for (final a in AppAccent.values) accentSeeds[a]!.dark],
        light: const Color(0xFFF6F4EF),
        dark: const Color(0xFF1A1C20),
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
                    GlobeGlyph(size: 18, color: p.textBrand),
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

/// The consent line with the Terms link. The summary opens in a sheet over
/// the form, so nothing typed is lost.
class TermsConsent extends StatelessWidget {
  const TermsConsent({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    return Material(
      color: p.bgSunken,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => showTermsSheet(context),
        child: Padding(
          padding: const EdgeInsets.all(Space.s12),
          child: Row(
            children: [
              Icon(AppIcons.lockKey, size: Sizes.iconMd, color: p.textBrand),
              const SizedBox(width: Space.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.termsConsent,
                      style: type.caption.copyWith(color: p.textSecondary),
                    ),
                    const SizedBox(height: Space.s2),
                    Text(
                      l10n.termsAndPrivacy,
                      style: type.label.copyWith(color: p.textBrand),
                    ),
                  ],
                ),
              ),
              Icon(
                Directionality.of(context) == TextDirection.rtl
                    ? AppIcons.caretLeft
                    : AppIcons.caretRight,
                size: Sizes.iconSm,
                color: p.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showTermsSheet(BuildContext context) => showAppSheet<void>(
  context: context,
  title: context.l10n.termsAndPrivacy,
  builder: (_) => const TermsSummary(),
);

/// What the terms say, in plain language, until the reviewed legal text
/// exists (owner action AD-06). Every point describes how the product
/// already behaves; the draft notice says the full text is still to come.
class TermsSummary extends StatelessWidget {
  const TermsSummary({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final points = [
      (AppIcons.storefront, l10n.termsPoint1Title, l10n.termsPoint1Body),
      (AppIcons.sealCheck, l10n.termsPoint2Title, l10n.termsPoint2Body),
      (AppIcons.sparkle, l10n.termsPoint3Title, l10n.termsPoint3Body),
      (AppIcons.trash, l10n.termsPoint4Title, l10n.termsPoint4Body),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < points.length; i++)
          _StaggerIn(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: Space.s16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: p.bgBrandWeak,
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                    child: Icon(
                      points[i].$1,
                      size: Sizes.iconMd,
                      color: p.textBrand,
                    ),
                  ),
                  const SizedBox(width: Space.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          points[i].$2,
                          style: type.bodyStrong.copyWith(color: p.textPrimary),
                        ),
                        const SizedBox(height: Space.s2),
                        Text(
                          points[i].$3,
                          style: type.body.copyWith(color: p.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        _StaggerIn(
          index: points.length,
          child: Container(
            padding: const EdgeInsets.all(Space.s12),
            decoration: BoxDecoration(
              color: p.bgPencil,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Text(
              l10n.termsPendingBody,
              style: type.caption.copyWith(color: p.textPencil),
            ),
          ),
        ),
      ],
    );
  }
}

/// Fades and lifts list items in one after another (motion.stagger).
class _StaggerIn extends StatelessWidget {
  const _StaggerIn({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return child;
    final delay = 60 * index;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 320 + delay),
      curve: Interval(delay / (320 + delay), 1, curve: MotionTokens.enter),
      child: child,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - v)),
          child: child,
        ),
      ),
    );
  }
}

/// Strength of a new password, from length and variety. Advisory only; the
/// rule that blocks submission stays `validateNewPassword`.
int passwordStrength(String s) {
  if (s.isEmpty) return 0;
  if (s.length < 8) return 1;
  var kinds = 0;
  if (RegExp('[a-z]').hasMatch(s)) kinds++;
  if (RegExp('[A-Z]').hasMatch(s)) kinds++;
  if (RegExp(r'\d').hasMatch(s)) kinds++;
  if (RegExp(r'[^A-Za-z0-9]').hasMatch(s)) kinds++;
  return s.length >= 12 && kinds >= 3 ? 3 : 2;
}

/// Three segments that fill and recolour as the password gets stronger.
class PasswordStrengthMeter extends StatelessWidget {
  const PasswordStrengthMeter({super.key, required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final level = passwordStrength(password);
    final (color, label) = switch (level) {
      1 => (p.dangerFg, l10n.passwordStrengthWeak),
      2 => (p.warningFg, l10n.passwordStrengthFair),
      3 => (p.successFg, l10n.passwordStrengthStrong),
      _ => (p.borderControl, ''),
    };
    final duration = Motion.fade(context, MotionTokens.md);
    return Padding(
      padding: const EdgeInsets.only(top: Space.s8),
      child: Row(
        children: [
          for (var i = 1; i <= 3; i++) ...[
            Expanded(
              child: AnimatedContainer(
                duration: duration,
                curve: MotionTokens.standard,
                height: 4,
                decoration: BoxDecoration(
                  color: i <= level ? color : p.bgSunken,
                  borderRadius: BorderRadius.circular(Radii.full),
                ),
              ),
            ),
            const SizedBox(width: Space.s4),
          ],
          const SizedBox(width: Space.s4),
          SizedBox(
            width: 64,
            child: AnimatedSwitcher(
              duration: duration,
              child: Text(
                label,
                key: ValueKey(level),
                textAlign: TextAlign.end,
                style: type.caption.copyWith(color: color),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
