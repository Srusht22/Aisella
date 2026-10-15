import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/route_guard.dart';
import '../../../core/formatting/money.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/pencil.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';

/// AU-02 Welcome: up to three skippable panels, each with a real UI fragment
/// (not an illustration), and both actions reachable without swiping.
/// Panels never auto-advance and make no claim of a connected channel.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _pages = PageController();
  int _index = 0;

  static const _count = 3;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    final reduced = Motion.reduced(context);
    if (reduced) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(
        index,
        duration: const Duration(milliseconds: 260),
        curve: MotionTokens.standard,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final panels = [
      (
        l10n.welcomePanel1Title,
        l10n.welcomePanel1Body,
        const _CatalogFragment(),
      ),
      (
        l10n.welcomePanel2Title,
        l10n.welcomePanel2Body,
        const _ApproveFragment(),
      ),
      (l10n.welcomePanel3Title, l10n.welcomePanel3Body, const _StockFragment()),
    ];
    final last = _index == _count - 1;

    return Scaffold(
      backgroundColor: p.bgCanvas,
      body: SafeArea(
        child: ContentWidth(
          maxWidth: LayoutTokens.maxWidthForm,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Text(
                      l10n.appName.toLowerCase(),
                      style: type.title.copyWith(
                        color: p.brandPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (!last)
                      TextButton(
                        onPressed: () => _goTo(_count - 1),
                        child: Text(l10n.welcomeSkip),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (i) => setState(() => _index = i),
                  children: [
                    for (final (title, body, fragment) in panels)
                      _Panel(title: title, body: body, fragment: fragment),
                  ],
                ),
              ),
              Semantics(
                label: l10n.welcomePanelPosition(_index + 1, _count),
                child: ExcludeSemantics(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _count; i++)
                        AnimatedContainer(
                          duration: Motion.spatial(context, MotionTokens.sm),
                          margin: const EdgeInsets.symmetric(
                            horizontal: Space.s4,
                          ),
                          width: i == _index ? 20 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: i == _index
                                ? p.brandPrimary
                                : p.borderControl,
                            borderRadius: BorderRadius.circular(Radii.full),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.s24),
              AppButton(
                label: l10n.welcomeCreateAccount,
                expand: true,
                onPressed: () => context.go(Routes.signUp),
              ),
              const SizedBox(height: Space.s12),
              AppButton(
                label: l10n.welcomeHaveAccount,
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: () => context.go(Routes.signIn),
              ),
              if (!last)
                Center(
                  child: TextButton(
                    onPressed: () => _goTo(_index + 1),
                    child: Text(l10n.welcomeNext),
                  ),
                )
              else
                const SizedBox(height: 48 + Space.s8),
              const SizedBox(height: Space.s8),
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.body,
    required this.fragment,
  });

  final String title;
  final String body;
  final Widget fragment;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: Space.s16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight - Space.s32,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Fragments are illustrative UI, not controls.
              ExcludeSemantics(child: IgnorePointer(child: fragment)),
              const SizedBox(height: Space.s32),
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: type.titleLarge.copyWith(color: p.textPrimary),
                ),
              ),
              const SizedBox(height: Space.s8),
              Text(
                body,
                style: type.bodyLarge.copyWith(color: p.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CatalogFragment extends StatelessWidget {
  const _CatalogFragment();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    final l10n = context.l10n;
    // A catalog fact as Aisellia would quote it: price and stock, in pencil
    // because a suggestion is never final until the seller sends it.
    return PencilBox(
      child: Row(
        children: [
          Icon(AppIcons.package, color: p.textPencil, size: Sizes.iconMd),
          const SizedBox(width: Space.s8),
          Expanded(
            child: Text(
              Money.format(
                35000,
                Currency.iqd,
                locale: Localizations.localeOf(context),
                digits: DigitStyle.western,
              ),
              style: type.numericBody.copyWith(color: p.textPrimary),
            ),
          ),
          StockIndicator(
            state: StockState.inStock,
            label: l10n.stockInStock('4'),
          ),
        ],
      ),
    );
  }
}

class _ApproveFragment extends StatelessWidget {
  const _ApproveFragment();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      StatusBadge(
        label: context.l10n.statusNeedsApproval,
        icon: AppIcons.pencilSimple,
        tone: Tone.pencil,
      ),
      const SizedBox(height: Space.s12),
      AppButton(label: context.l10n.approveOrder, onPressed: () {}),
    ],
  );
}

class _StockFragment extends StatelessWidget {
  const _StockFragment();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        StockIndicator(
          state: StockState.inStock,
          label: context.l10n.stockInStock('4'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.s8),
          child: Icon(
            AppIcons.arrowRight,
            size: Sizes.iconSm,
            color: p.textTertiary,
          ),
        ),
        StockIndicator(
          state: StockState.inStock,
          label: context.l10n.stockInStock('3'),
          emphasizeAvailable: true,
        ),
      ],
    );
  }
}
