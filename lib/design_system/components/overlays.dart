import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../layout/responsive.dart';
import '../motion/motion.dart';
import '../theme/theme_ext.dart';
import '../tokens/tokens.g.dart';
import 'app_button.dart';

/// Presents a bottom sheet with the Aisellia anatomy (drag handle, title,
/// content, actions) and motion (enter 280 ms / exit 200 ms). On expanded
/// windows it is shown as a centred dialog (Phase 2 IA §3.3).
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  bool isDismissible = true,
}) {
  final windowClass = WindowClass.of(context);
  if (windowClass.index >= WindowClass.expanded.index) {
    return showDialog<T>(
      context: context,
      barrierDismissible: isDismissible,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: LayoutTokens.maxWidthForm,
          ),
          child: _SheetBody(title: title, builder: builder, showHandle: false),
        ),
      ),
    );
  }
  final reduced = Motion.reduced(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: isDismissible,
    useSafeArea: true,
    sheetAnimationStyle: AnimationStyle(
      duration: reduced ? MotionTokens.sm : MotionTokens.sheetEnter,
      reverseDuration: reduced ? MotionTokens.sm : MotionTokens.sheetExit,
      curve: MotionTokens.enter,
      reverseCurve: MotionTokens.exit,
    ),
    builder: (context) =>
        _SheetBody(title: title, builder: builder, showHandle: true),
  );
}

class _SheetBody extends StatelessWidget {
  const _SheetBody({
    required this.title,
    required this.builder,
    required this.showHandle,
  });

  final String title;
  final WidgetBuilder builder;
  final bool showHandle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHandle)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: Space.s8),
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: p.borderControl,
                      borderRadius: BorderRadius.circular(Radii.full),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                Space.s16,
                Space.s16,
                Space.s16,
                Space.s8,
              ),
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: context.type.title.copyWith(color: p.textPrimary),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  Space.s16,
                  0,
                  Space.s16,
                  Space.s16,
                ),
                child: Builder(builder: builder),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Destructive or important confirmation (Phase 2 CMP-Dialog). The safe
/// option has default focus; the confirm button uses danger style when
/// [destructive]. Returns true only if the user confirmed.
Future<bool> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String body,
  required String confirmLabel,
  required String cancelLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        AppButton(
          label: cancelLabel,
          variant: AppButtonVariant.tertiary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        AppButton(
          label: confirmLabel,
          variant: destructive
              ? AppButtonVariant.danger
              : AppButtonVariant.primary,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Shows the standard "Discard changes?" dialog (GL-06).
Future<bool> confirmDiscard(BuildContext context) {
  final l10n = context.l10n;
  return showConfirmDialog(
    context: context,
    title: l10n.discardTitle,
    body: l10n.discardBody,
    confirmLabel: l10n.discard,
    cancelLabel: l10n.keepEditing,
    destructive: true,
  );
}

/// Blocks back/swipe navigation while [dirty] and asks before discarding
/// (Phase 2 IA §3.5). Wrap full-screen editors with it.
class UnsavedChangesGuard extends StatelessWidget {
  const UnsavedChangesGuard({
    super.key,
    required this.dirty,
    required this.child,
  });

  final bool dirty;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await confirmDiscard(context)) navigator.pop();
      },
      child: child,
    );
  }
}

/// Sticky bottom action area with an optional reason line explaining a
/// disabled primary (Phase 2 CMP-StickyActionBar). Buttons stack vertically
/// when they don't fit side by side; secondary at start, primary at end.
class StickyActionBar extends StatelessWidget {
  const StickyActionBar({
    super.key,
    required this.primary,
    this.secondary,
    this.reason,
  });

  final Widget primary;
  final Widget? secondary;
  final Widget? reason;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final largeText = MediaQuery.textScalerOf(context).scale(10) >= 15;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.bgSurface,
        border: Border(
          top: BorderSide(color: p.borderHairline, width: Strokes.hairline),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            Space.s16,
            Space.s12,
            Space.s16,
            Space.s12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (reason != null) ...[
                reason!,
                const SizedBox(height: Space.s8),
              ],
              LayoutBuilder(
                builder: (context, constraints) {
                  if (secondary == null) return primary;
                  if (largeText || constraints.maxWidth < 320) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        primary,
                        const SizedBox(height: Space.s8),
                        secondary!,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      secondary!,
                      const SizedBox(width: Space.s8),
                      Expanded(child: primary),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
