import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../icons/app_icons.dart';
import '../motion/motion.dart';
import '../motion/primitives.dart';
import '../theme/theme_ext.dart';
import '../tokens/tokens.g.dart';
import 'app_button.dart';
import 'status.dart';

/// Inline banner (Phase 2 CMP-Banner): persistent state of the current screen.
class AppBanner extends StatelessWidget {
  const AppBanner({
    super.key,
    required this.tone,
    required this.icon,
    required this.title,
    this.body,
    this.action,
  });

  final Tone tone;
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = toneColors(context, tone);
    final type = context.type;
    return FadeSlideIn(
      child: Semantics(
        container: true,
        liveRegion: tone == Tone.danger,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Padding(
            padding: const EdgeInsets.all(Space.s12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: Sizes.iconMd, color: c.fg),
                const SizedBox(width: Space.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: type.bodyStrong.copyWith(color: c.fg)),
                      if (body != null) ...[
                        const SizedBox(height: Space.s2),
                        Text(body!, style: type.label.copyWith(color: c.fg)),
                      ],
                      if (action != null) ...[
                        const SizedBox(height: Space.s4),
                        action!,
                      ],
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

/// Marks screens fed by fictional sample data (Phase 2 §14; Phase 4 §11).
class SampleDataBanner extends StatelessWidget {
  const SampleDataBanner({super.key});

  @override
  Widget build(BuildContext context) => AppBanner(
    tone: Tone.info,
    icon: AppIcons.flask,
    title: context.l10n.sampleDataTitle,
    body: context.l10n.sampleDataBody,
  );
}

/// First-use empty state (P-EMPTY): icon circle, title, one sentence,
/// optional action. Placed at ~30 % of the space, not floating in a void.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
  });

  final IconData icon;
  final String title;

  /// One explanatory sentence; omitted when the title says it all.
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: LayoutTokens.maxWidthForm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.s24,
            vertical: Space.s32,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: p.bgSunken,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: 64,
                  child: Icon(icon, size: Sizes.iconLg, color: p.textSecondary),
                ),
              ),
              const SizedBox(height: Space.s16),
              Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: type.heading.copyWith(color: p.textPrimary),
                ),
              ),
              if (body case final body?) ...[
                const SizedBox(height: Space.s8),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: type.body.copyWith(color: p.textSecondary),
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: Space.s16),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Load failure (P-ERR-LOAD): cause line, Retry, optional support reference.
/// Never shows stack traces or internal messages.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.cause,
    required this.onRetry,
    this.reference,
  });

  final String cause;
  final VoidCallback onRetry;
  final String? reference;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EmptyState(
      icon: AppIcons.warningCircle,
      title: l10n.errorLoadTitle,
      body: reference == null
          ? cause
          : '$cause\n${l10n.errorReference(reference!)}',
      action: AppButton(
        label: l10n.retry,
        icon: AppIcons.arrowClockwise,
        variant: AppButtonVariant.secondary,
        onPressed: onRetry,
      ),
    );
  }
}

/// Skeleton placeholder (P-LOAD-LIST): appears only after 300 ms, one slow
/// synchronized opacity pulse, static under reduced motion. No shimmer.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, required this.child});

  /// Layout made of [SkeletonBlock]s mirroring the real content geometry.
  final Widget child;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: MotionTokens.skeletonPulse,
  );
  Timer? _delay;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _delay = Timer(MotionTokens.skeletonDelay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _pulse.stop();
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.loading,
      liveRegion: true,
      child: ExcludeSemantics(
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: MotionTokens.sm,
          child: FadeTransition(
            opacity: Tween(
              begin: MotionTokens.skeletonMinOpacity,
              end: 1.0,
            ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({super.key, this.width, required this.height});

  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: context.palette.bgSunken,
      borderRadius: BorderRadius.circular(Radii.sm),
    ),
  );
}

/// Snackbar for completed non-critical actions (Phase 2 CMP-Snackbar).
/// No Undo in P0.
void showAppSnackBar(BuildContext context, String message) =>
    showSnackOn(ScaffoldMessenger.of(context), message);

/// Same as [showAppSnackBar] for a messenger captured before an `await`
/// (the widget may be gone by the time the result arrives). A new message
/// replaces the current one instead of queueing behind it.
void showSnackOn(ScaffoldMessengerState messenger, String message) => messenger
  ..hideCurrentSnackBar()
  ..showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
  );
