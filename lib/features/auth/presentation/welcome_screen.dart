import 'dart:math' as math;

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
import '../../../design_system/motion/primitives.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import 'auth_page.dart';

/// AU-02 Welcome: three skippable panels. Each panel plays a short scene of
/// the real product (a customer question answered from the catalog, a draft
/// approved, stock going down) once when it becomes active, then holds still
/// (Phase 2 §06: motion explains, stillness is the default). Under reduced
/// motion every scene shows its final state. Both actions stay reachable
/// without swiping, and nothing claims a connected channel.
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
    if (Motion.reduced(context)) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(
        index,
        duration: MotionTokens.lg,
        curve: MotionTokens.standard,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final panels = [
      (l10n.welcomePanel1Title, l10n.welcomePanel1Body, _Scene.chat),
      (l10n.welcomePanel2Title, l10n.welcomePanel2Body, _Scene.approve),
      (l10n.welcomePanel3Title, l10n.welcomePanel3Body, _Scene.stock),
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
                    const Expanded(child: _Wordmark()),
                    const LanguageButton(),
                    AnimatedOpacity(
                      opacity: last ? 0 : 1,
                      duration: Motion.fade(context, MotionTokens.sm),
                      child: IgnorePointer(
                        ignoring: last,
                        child: TextButton(
                          onPressed: () => _goTo(_count - 1),
                          child: Text(l10n.welcomeSkip),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (i) => setState(() => _index = i),
                  children: [
                    for (var i = 0; i < panels.length; i++)
                      _Panel(
                        index: i,
                        controller: _pages,
                        active: i == _index,
                        title: panels[i].$1,
                        body: panels[i].$2,
                        scene: panels[i].$3,
                      ),
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
                          duration: Motion.spatial(context, MotionTokens.md),
                          curve: MotionTokens.standard,
                          margin: const EdgeInsets.symmetric(
                            horizontal: Space.s4,
                          ),
                          width: i == _index ? 24 : 8,
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
              SizedBox(
                height: 48 + Space.s8,
                child: last
                    ? null
                    : Center(
                        child: TextButton(
                          onPressed: () => _goTo(_index + 1),
                          child: Text(l10n.welcomeNext),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The wordmark: the app name with a small pencil-to-ink mark.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: p.brandPrimary,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Icon(
            AppIcons.sparkleFill,
            size: Sizes.iconSm,
            color: p.textOnBrand,
          ),
        ),
        const SizedBox(width: Space.s8),
        Flexible(
          child: Text(
            context.l10n.appName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.title.copyWith(
              color: p.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

enum _Scene { chat, approve, stock }

/// One panel: the scene on a stage, then the title and body, which enter
/// in sequence. The stage drifts with the swipe for depth.
class _Panel extends StatefulWidget {
  const _Panel({
    required this.index,
    required this.controller,
    required this.active,
    required this.title,
    required this.body,
    required this.scene,
  });

  final int index;
  final PageController controller;
  final bool active;
  final String title;
  final String body;
  final _Scene scene;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> with SingleTickerProviderStateMixin {
  // One timeline per panel; every element reads its own interval from it.
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _t.value = 1;
    } else if (widget.active && !_t.isAnimating && _t.value == 0) {
      _t.forward();
    }
  }

  @override
  void didUpdateWidget(_Panel old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      if (Motion.reduced(context)) {
        _t.value = 1;
      } else {
        _t.forward(from: 0);
      }
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
    final reduced = Motion.reduced(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;

    final stage = _Stage(
      child: switch (widget.scene) {
        _Scene.chat => _ChatScene(t: _t),
        _Scene.approve => _ApproveScene(t: _t),
        _Scene.stock => _StockScene(t: _t),
      },
    );

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: Space.s8),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight - Space.s16,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Scenes are illustrative UI, not controls.
              ExcludeSemantics(
                child: IgnorePointer(
                  child: reduced
                      ? stage
                      : AnimatedBuilder(
                          animation: widget.controller,
                          child: stage,
                          builder: (context, child) {
                            final page =
                                widget.controller.hasClients &&
                                    widget
                                        .controller
                                        .position
                                        .hasContentDimensions
                                ? widget.controller.page ??
                                      widget.index.toDouble()
                                : widget.index.toDouble();
                            final delta = (page - widget.index).clamp(
                              -1.0,
                              1.0,
                            );
                            // The stage lags behind the page: depth.
                            final dx = delta * 56 * (rtl ? -1 : 1);
                            return Opacity(
                              opacity: 1 - delta.abs() * 0.6,
                              child: Transform.translate(
                                offset: Offset(dx, 0),
                                child: Transform.scale(
                                  scale: 1 - delta.abs() * 0.06,
                                  child: child,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: Space.s32),
              _Enter(
                t: _t,
                begin: 0,
                child: Semantics(
                  header: true,
                  child: Text(
                    widget.title,
                    style: type.titleLarge.copyWith(color: p.textPrimary),
                  ),
                ),
              ),
              const SizedBox(height: Space.s8),
              _Enter(
                t: _t,
                begin: 0.06,
                child: Text(
                  widget.body,
                  style: type.bodyLarge.copyWith(color: p.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Progress of [t] through [begin]..[end], eased.
double _phase(
  double t,
  double begin,
  double end, [
  Curve curve = MotionTokens.enter,
]) => curve.transform(((t - begin) / (end - begin)).clamp(0.0, 1.0));

/// Fades and lifts [child] in over the interval starting at [begin].
class _Enter extends StatelessWidget {
  const _Enter({
    required this.t,
    required this.begin,
    required this.child,
    this.length = 0.16,
    this.distance = 14,
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
      final v = _phase(t.value, begin, begin + length);
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

/// The raised surface every scene plays on, with a soft brand wash behind
/// the content so the scene reads as a focal point.
class _Stage extends StatelessWidget {
  const _Stage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      constraints: const BoxConstraints(minHeight: 300),
      decoration: BoxDecoration(
        color: p.bgSurface,
        borderRadius: BorderRadius.circular(Radii.lg + 8),
        border: Border.all(color: p.borderHairline),
        boxShadow: [
          BoxShadow(
            color: p.brandPrimary.withValues(alpha: 0.10),
            blurRadius: 40,
            spreadRadius: -8,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          PositionedDirectional(
            top: -120,
            end: -90,
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    p.brandPrimary.withValues(alpha: 0.16),
                    p.brandPrimary.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          Padding(padding: const EdgeInsets.all(Space.s20), child: child),
        ],
      ),
    );
  }
}

/// Panel 1: a customer asks, Aisellia drafts a reply in pencil from the
/// catalog, and the facts it used appear underneath.
class _ChatScene extends StatelessWidget {
  const _ChatScene({required this.t});

  final Animation<double> t;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final locale = Localizations.localeOf(context);
    final price = Money.format(
      35000,
      Currency.iqd,
      locale: locale,
      digits: DigitStyle.western,
    );

    return AnimatedBuilder(
      animation: t,
      builder: (context, _) {
        final v = t.value;
        final typing = v > 0.2 && v < 0.46;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Enter(
              t: t,
              begin: 0,
              child: Row(
                children: [
                  _Avatar(letter: l10n.welcomeDemoCustomer.characters.first),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: Text(
                      l10n.welcomeDemoCustomer,
                      style: type.bodyStrong.copyWith(color: p.textPrimary),
                    ),
                  ),
                  Icon(
                    AppIcons.chatsCircle,
                    size: Sizes.iconSm,
                    color: p.textTertiary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.s12),
            _Enter(
              t: t,
              begin: 0.06,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: _Bubble(
                  color: p.bgSunken,
                  child: Text(
                    l10n.welcomeDemoQuestion,
                    style: type.body.copyWith(color: p.textPrimary),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.s12),
            // The reply sizes the area; the typing dots sit over it until
            // the reply appears.
            Stack(
              children: [
                Align(
                  alignment: AlignmentDirectional.topEnd,
                  child: _Enter(
                    t: t,
                    begin: 0.46,
                    length: 0.14,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 290),
                      child: PencilBox(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  AppIcons.sparkle,
                                  size: 14,
                                  color: p.textPencil,
                                ),
                                const SizedBox(width: Space.s4),
                                Text(
                                  l10n.welcomeDemoSuggestion,
                                  style: type.caption.copyWith(
                                    color: p.textPencil,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: Space.s4),
                            Text(
                              l10n.welcomeDemoReply(price, '4'),
                              style: type.body.copyWith(color: p.textPrimary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (typing)
                  PositionedDirectional(
                    top: 0,
                    end: 0,
                    child: _Bubble(
                      color: p.bgPencil,
                      child: _TypingDots(phase: (v - 0.2) / 0.26),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Space.s4),
            Wrap(
              spacing: Space.s8,
              runSpacing: Space.s8,
              alignment: WrapAlignment.end,
              children: [
                _Pop(
                  t: t,
                  begin: 0.66,
                  child: _FactChip(
                    icon: AppIcons.package,
                    label: l10n.welcomeDemoProduct,
                  ),
                ),
                _Pop(
                  t: t,
                  begin: 0.74,
                  child: _FactChip(icon: AppIcons.money, label: price),
                ),
                _Pop(
                  t: t,
                  begin: 0.82,
                  child: _FactChip(
                    icon: AppIcons.checkCircle,
                    label: l10n.stockInStock('4'),
                    tone: Tone.success,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Panel 2: an order draft fills in, the approve button is pressed, and the
/// pencil settles into ink.
class _ApproveScene extends StatelessWidget {
  const _ApproveScene({required this.t});

  final Animation<double> t;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final locale = Localizations.localeOf(context);
    String iqd(int v) => Money.format(
      v,
      Currency.iqd,
      locale: locale,
      digits: DigitStyle.western,
    );

    return AnimatedBuilder(
      animation: t,
      builder: (context, _) {
        final v = t.value;
        final approved = v >= 0.72;
        // Press: in over 0.60–0.66, release by 0.72.
        final press = v < 0.6
            ? 0.0
            : v < 0.66
            ? _phase(v, 0.6, 0.66, Curves.easeOut)
            : 1 - _phase(v, 0.66, 0.72, Curves.easeOut);

        Widget line(String a, String b, double begin, {bool strong = false}) =>
            _Enter(
              t: t,
              begin: begin,
              length: 0.12,
              distance: 8,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.s4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        a,
                        style: (strong ? type.bodyStrong : type.body).copyWith(
                          color: strong ? p.textPrimary : p.textSecondary,
                        ),
                      ),
                    ),
                    Text(
                      b,
                      style: (strong ? type.numericTotal : type.numericBody)
                          .copyWith(color: p.textPrimary),
                    ),
                  ],
                ),
              ),
            );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PencilBox(
              settled: approved,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Enter(
                    t: t,
                    begin: 0,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.welcomeDemoOrderTitle,
                            style: type.heading.copyWith(color: p.textPrimary),
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: Motion.fade(context, MotionTokens.md),
                          switchInCurve: MotionTokens.enter,
                          transitionBuilder: (child, a) => FadeTransition(
                            opacity: a,
                            child: ScaleTransition(
                              scale: Tween(begin: 0.85, end: 1.0).animate(a),
                              child: child,
                            ),
                          ),
                          child: approved
                              ? StatusBadge(
                                  key: const ValueKey('ok'),
                                  label: l10n.statusApproved,
                                  icon: AppIcons.sealCheck,
                                  tone: Tone.success,
                                )
                              : StatusBadge(
                                  key: const ValueKey('draft'),
                                  label: l10n.statusNeedsApproval,
                                  icon: AppIcons.pencilSimple,
                                  tone: Tone.pencil,
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s8),
                  line(l10n.welcomeDemoCustomer, '', 0.1),
                  line('${l10n.welcomeDemoProduct} × 2', iqd(70000), 0.18),
                  line(l10n.deliveryFee, iqd(5000), 0.26),
                  _Enter(
                    t: t,
                    begin: 0.32,
                    child: Divider(height: Space.s16, color: p.borderHairline),
                  ),
                  line(l10n.total, iqd(75000), 0.36, strong: true),
                ],
              ),
            ),
            const SizedBox(height: Space.s16),
            _Enter(
              t: t,
              begin: 0.44,
              child: Transform.scale(
                scale: 1 - press * 0.04,
                child: AnimatedContainer(
                  duration: Motion.fade(context, MotionTokens.md),
                  curve: MotionTokens.standard,
                  height: 48,
                  decoration: BoxDecoration(
                    color: approved
                        ? p.successBg
                        : Color.lerp(
                            p.brandPrimary,
                            p.brandPrimaryPressed,
                            press,
                          ),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  alignment: Alignment.center,
                  child: AnimatedSwitcher(
                    duration: Motion.fade(context, MotionTokens.sm),
                    child: Row(
                      key: ValueKey(approved),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          approved ? AppIcons.checkCircleFill : AppIcons.check,
                          size: Sizes.iconMd,
                          color: approved ? p.successFg : p.textOnBrand,
                        ),
                        const SizedBox(width: Space.s8),
                        Text(
                          approved ? l10n.statusApproved : l10n.approveOrder,
                          style: type.button.copyWith(
                            color: approved ? p.successFg : p.textOnBrand,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Panel 3: approving the order takes one item out of stock; the count rolls
/// down and the stock bar shortens.
class _StockScene extends StatelessWidget {
  const _StockScene({required this.t});

  final Animation<double> t;

  static const _max = 6;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final locale = Localizations.localeOf(context);

    return AnimatedBuilder(
      animation: t,
      builder: (context, _) {
        final v = t.value;
        final sold = v >= 0.5;
        final count = sold ? 3 : 4;
        final bar = (4 - _phase(v, 0.5, 0.7, MotionTokens.standard)) / _max;
        final floatUp = _phase(v, 0.46, 0.9, Curves.easeOut);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Enter(
              t: t,
              begin: 0,
              child: Row(
                children: [
                  Container(
                    width: Sizes.thumbList,
                    height: Sizes.thumbList,
                    decoration: BoxDecoration(
                      color: p.bgBrandWeak,
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                    child: Icon(
                      AppIcons.packageFill,
                      color: p.brandPrimary,
                      size: Sizes.iconLg,
                    ),
                  ),
                  const SizedBox(width: Space.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.welcomeDemoProduct,
                          style: type.bodyStrong.copyWith(color: p.textPrimary),
                        ),
                        Text(
                          Money.format(
                            35000,
                            Currency.iqd,
                            locale: locale,
                            digits: DigitStyle.western,
                          ),
                          style: type.numericBody.copyWith(
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.s24),
            _Enter(
              t: t,
              begin: 0.1,
              child: SizedBox(
                height: 64,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: NumberRoll(
                        value: count,
                        text: l10n.stockInStock('$count'),
                        style: type.numericMetric.copyWith(
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    if (v > 0.46 && floatUp < 1)
                      _FloatTag(
                        progress: floatUp,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.s12,
                            vertical: Space.s4,
                          ),
                          decoration: BoxDecoration(
                            color: p.brandPrimary,
                            borderRadius: BorderRadius.circular(Radii.full),
                            boxShadow: [
                              BoxShadow(
                                color: p.brandPrimary.withValues(alpha: 0.4),
                                blurRadius: 16,
                              ),
                            ],
                          ),
                          // A signed number reads left to right in every
                          // language.
                          child: Text(
                            '−1',
                            textDirection: TextDirection.ltr,
                            style: type.numericBody.copyWith(
                              color: p.textOnBrand,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.s12),
            _Enter(
              t: t,
              begin: 0.16,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.full),
                child: SizedBox(
                  height: 8,
                  child: Stack(
                    children: [
                      Container(color: p.bgSunken),
                      FractionallySizedBox(
                        widthFactor: bar,
                        alignment: AlignmentDirectional.centerStart,
                        child: Container(color: p.successFg),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.s24),
            SizedBox(
              height: 40,
              child: _Enter(
                t: t,
                begin: 0.52,
                child: Row(
                  children: [
                    Icon(
                      AppIcons.sealCheckFill,
                      size: Sizes.iconMd,
                      color: p.successFg,
                    ),
                    const SizedBox(width: Space.s8),
                    Expanded(
                      child: Text(
                        l10n.welcomeDemoStockEvent,
                        style: type.body.copyWith(color: p.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A "−1" tag that rises from the stock count and fades.
class _FloatTag extends StatelessWidget {
  const _FloatTag({required this.progress, required this.child});

  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerEnd,
    child: Opacity(
      opacity: progress < 0.7 ? 1 : 1 - (progress - 0.7) / 0.3,
      child: Transform.translate(
        offset: Offset(0, -36 * progress),
        child: child,
      ),
    ),
  );
}

/// Scales and fades [child] in, starting at [begin].
class _Pop extends StatelessWidget {
  const _Pop({required this.t, required this.begin, required this.child});

  final Animation<double> t;
  final double begin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final v = _phase(t.value, begin, begin + 0.12, Curves.easeOutBack);
    return Opacity(
      opacity: v.clamp(0.0, 1.0),
      child: Transform.scale(scale: 0.8 + 0.2 * v, child: child),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 260),
    padding: const EdgeInsets.symmetric(
      horizontal: Space.s12,
      vertical: Space.s8,
    ),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(Radii.lg),
    ),
    child: child,
  );
}

/// Three dots that bounce in turn; [phase] runs 0..1 over the typing time,
/// so the dots stop with the scene.
class _TypingDots extends StatelessWidget {
  const _TypingDots({required this.phase});

  final double phase;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Transform.translate(
                offset: Offset(
                  0,
                  -4 * math.max(0, math.sin((phase * 3 - i * 0.25) * math.pi)),
                ),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: p.textPencil,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.letter});

  final String letter;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: p.bgBrandWeak, shape: BoxShape.circle),
      child: Text(
        letter,
        style: context.type.bodyStrong.copyWith(color: p.textBrand),
      ),
    );
  }
}

class _FactChip extends StatelessWidget {
  const _FactChip({
    required this.icon,
    required this.label,
    this.tone = Tone.neutral,
  });

  final IconData icon;
  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final c = toneColors(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.s8,
        vertical: Space.s4,
      ),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(Radii.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c.fg),
          const SizedBox(width: Space.s4),
          Text(label, style: context.type.label.copyWith(color: c.fg)),
        ],
      ),
    );
  }
}
