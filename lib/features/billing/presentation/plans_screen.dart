import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/digits.dart';
import '../../../core/l10n/l10n.dart';
import '../../../design_system/brand/app_logo.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/motion/primitives.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/header_controls.dart';
import '../../common/plan_labels.dart';
import '../application/plan_controller.dart';
import '../domain/plan.dart';

/// The plans, shown after sign-up and before the guest demo, and from the
/// store menu. Picking a plan starts its 7-day free trial; nothing is
/// charged (no payment provider is connected yet).
class PlansScreen extends ConsumerStatefulWidget {
  const PlansScreen({super.key, required this.onContinue, this.onGuest});

  /// Called after the trial starts (or the plan changes).
  final void Function(BuildContext context) onContinue;

  /// When set, a "Continue as a guest" button is shown at the bottom.
  final void Function(BuildContext context)? onGuest;

  @override
  ConsumerState<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends ConsumerState<PlansScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  PlanTier? _selected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _selected = ref.read(planProvider).tier ?? PlanTier.pro;
  }

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

  Future<void> _start() async {
    final tier = _selected;
    if (tier == null || _busy) return;
    setState(() => _busy = true);
    await ref.read(planProvider.notifier).choose(tier);
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onContinue(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final current = ref.watch(planProvider);
    final trialUsed = current.trialStart != null;

    return Scaffold(
      backgroundColor: p.bgCanvas,
      body: SafeArea(
        child: Column(
          children: [
            ContentWidth(
              maxWidth: LayoutTokens.maxWidthForm,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    if (Navigator.of(context).canPop())
                      IconButton(
                        tooltip: MaterialLocalizations.of(context)
                            .backButtonTooltip,
                        icon: const Icon(AppIcons.arrowLeft),
                        onPressed: () => Navigator.of(context).maybePop(),
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
                padding: const EdgeInsets.only(bottom: Space.s24),
                children: [
                  ContentWidth(
                    maxWidth: LayoutTokens.maxWidthForm,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Rise(
                          t: _t,
                          begin: 0,
                          child: const Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: AppLogo(size: 48, glow: true),
                          ),
                        ),
                        const SizedBox(height: Space.s16),
                        _Rise(
                          t: _t,
                          begin: 0.08,
                          child: Semantics(
                            header: true,
                            child: Text(
                              l10n.plansTitle,
                              style: type.titleLarge.copyWith(
                                color: p.textPrimary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: Space.s8),
                        _Rise(
                          t: _t,
                          begin: 0.14,
                          child: Text(
                            trialUsed ? l10n.plansChangeBody : l10n.plansBody,
                            style: type.bodyLarge.copyWith(
                              color: p.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(height: Space.s24),
                        for (final (i, tier) in PlanTier.values.indexed) ...[
                          _Rise(
                            t: _t,
                            begin: 0.22 + 0.1 * i,
                            distance: 24,
                            child: _PlanCard(
                              tier: tier,
                              selected: _selected == tier,
                              popular: tier == PlanTier.pro,
                              onTap: () => setState(() => _selected = tier),
                            ),
                          ),
                          const SizedBox(height: Space.s12),
                        ],
                        _Rise(
                          t: _t,
                          begin: 0.55,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                AppIcons.info,
                                size: Sizes.iconSm,
                                color: p.textTertiary,
                              ),
                              const SizedBox(width: Space.s8),
                              Expanded(
                                child: Text(
                                  l10n.plansNoCharge,
                                  style: type.caption.copyWith(
                                    color: p.textTertiary,
                                  ),
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
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: p.bgSurface,
                border: Border(top: BorderSide(color: p.borderHairline)),
              ),
              child: SafeArea(
                top: false,
                child: ContentWidth(
                  maxWidth: LayoutTokens.maxWidthForm,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.s12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppButton(
                          label: trialUsed
                              ? l10n.plansChoose(
                                  planName(l10n, _selected ?? PlanTier.pro),
                                )
                              : l10n.plansStartTrial,
                          icon: AppIcons.sparkle,
                          loading: _busy,
                          expand: true,
                          onPressed: _start,
                        ),
                        if (widget.onGuest != null) ...[
                          const SizedBox(height: Space.s4),
                          TextButton(
                            onPressed: () => widget.onGuest!(context),
                            child: Text(l10n.plansContinueGuest),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.tier,
    required this.selected,
    required this.popular,
    required this.onTap,
  });

  final PlanTier tier;
  final bool selected;
  final bool popular;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final duration = Motion.fade(context, MotionTokens.md);
    return Semantics(
      button: true,
      selected: selected,
      child: PressScale(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: duration,
            curve: MotionTokens.standard,
            padding: const EdgeInsets.all(Space.s16),
            decoration: BoxDecoration(
              color: selected ? p.bgBrandWeak : p.bgSurface,
              borderRadius: BorderRadius.circular(Radii.lg + 4),
              border: Border.all(
                color: selected ? p.brandPrimary : p.borderHairline,
                width: selected ? 2 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: p.brandPrimary.withValues(alpha: 0.18),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: Space.s8,
                        runSpacing: Space.s4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            planName(l10n, tier),
                            style: type.heading.copyWith(color: p.textPrimary),
                          ),
                          if (popular)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Space.s8,
                                vertical: Space.s2,
                              ),
                              decoration: BoxDecoration(
                                color: p.brandPrimary,
                                borderRadius: BorderRadius.circular(Radii.full),
                              ),
                              child: Text(
                                l10n.plansPopular,
                                style: type.caption.copyWith(
                                  color: p.textOnBrand,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: Space.s2),
                      Text(
                        planTagline(l10n, tier),
                        style: type.body.copyWith(color: p.textSecondary),
                      ),
                      const SizedBox(height: Space.s12),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '\$${tier.priceUsd}',
                              style: type.numericMetric.copyWith(
                                color: selected ? p.textBrand : p.textPrimary,
                              ),
                            ),
                            TextSpan(
                              text: ' ${l10n.plansPerMonth}',
                              style: type.body.copyWith(color: p.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: Text(
                              l10n.plansLimits,
                              style: type.caption.copyWith(
                                color: p.textTertiary,
                              ),
                            ),
                          ),
                          AnimatedScale(
                            scale: selected ? 1 : 0,
                            duration: Motion.spatial(context, MotionTokens.md),
                            curve: Curves.easeOutBack,
                            child: Icon(
                              AppIcons.checkCircleFill,
                              size: Sizes.iconMd,
                              color: p.brandPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.s8),
                      _Limit(
                        icon: AppIcons.package,
                        text: l10n.plansProducts(Digits.group(tier.products)),
                      ),
                      const SizedBox(height: Space.s8),
                      _Limit(
                        icon: AppIcons.receipt,
                        text: l10n.plansOrders(
                          Digits.group(tier.ordersPerMonth),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Limit extends StatelessWidget {
  const _Limit({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: Sizes.iconSm, color: p.textBrand),
        const SizedBox(width: Space.s8),
        Expanded(
          child: Text(
            text,
            style: context.type.bodyStrong.copyWith(color: p.textPrimary),
          ),
        ),
      ],
    );
  }
}

/// Fades and lifts [child] in over the part of [t] that starts at [begin].
class _Rise extends StatelessWidget {
  const _Rise({
    required this.t,
    required this.begin,
    required this.child,
    this.distance = 14,
  });

  final Animation<double> t;
  final double begin;
  final double distance;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: t,
    child: child,
    builder: (context, child) {
      final v = MotionTokens.enter.transform(
        ((t.value - begin) / 0.35).clamp(0.0, 1.0),
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
