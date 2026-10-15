import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/formatting/money.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/primitives.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/top_level_page.dart';
import '../data/today_repository.dart';

/// TD-01 Today: what needs the seller now, as rows — no KPI cards, no charts
/// (Phase 2 §4). Counts come from the repository; on failure an error is
/// shown, never zeros.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    final locale = Localizations.localeOf(context);
    final today = ref.watch(todayProvider);
    final date = Dates.weekdayDayMonth(
      DateTime.now(),
      locale: locale,
      digits: settings.digits,
    );

    final Widget content = switch (today) {
      AsyncData(value: TodayNoStore()) => EmptyState(
        icon: AppIcons.storefront,
        title: l10n.noStoreConnected,
        body: l10n.deferredBody,
      ),
      AsyncData(value: final TodayData data) => _TodayContent(data: data),
      AsyncError() => ErrorState(
        cause: l10n.errorServer,
        onRetry: () => ref.invalidate(todayProvider),
      ),
      _ => const _TodaySkeleton(),
    };

    return TopLevelPage(
      title: l10n.todayTitle,
      subtitle: date,
      contentMaxWidth: LayoutTokens.maxWidthDetailPane,
      slivers: [
        SliverToBoxAdapter(
          child: ContentWidth(
            maxWidth: LayoutTokens.maxWidthDetailPane,
            child: AnimatedSwitcher(duration: MotionTokens.sm, child: content),
          ),
        ),
      ],
    );
  }
}

class _TodayContent extends ConsumerWidget {
  const _TodayContent({required this.data});

  final TodayData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final digits = ref.watch(settingsProvider).digits;
    final locale = Localizations.localeOf(context);
    final s = data.snapshot;
    String count(int v) => Digits.display('$v', digits);
    String money(int v) =>
        Money.format(v, s.currency, locale: locale, digits: digits);

    void openOrders() => context.go(Routes.orders);
    void openInbox() => context.go(Routes.inbox);
    void openProducts() => context.go(Routes.products);

    final rows = <Widget>[
      if (s.needsApproval > 0)
        _AttentionRow(
          icon: AppIcons.pencilSimple,
          color: p.warningFg,
          label: l10n.attnNeedsApproval,
          value: s.needsApproval,
          text: count(s.needsApproval),
          onTap: openOrders,
        ),
      if (s.needsYou > 0)
        _AttentionRow(
          icon: AppIcons.flag,
          color: p.dangerFg,
          label: l10n.attnNeedsYou,
          value: s.needsYou,
          text: count(s.needsYou),
          onTap: openInbox,
        ),
      if (s.draftsMissing > 0)
        _AttentionRow(
          icon: AppIcons.pencilSimple,
          color: p.textSecondary,
          label: l10n.attnDraftsMissing,
          value: s.draftsMissing,
          text: count(s.draftsMissing),
          onTap: openOrders,
        ),
      if (s.toDispatch > 0)
        _AttentionRow(
          icon: AppIcons.package,
          color: p.textSecondary,
          label: l10n.attnToDispatch,
          value: s.toDispatch,
          text: count(s.toDispatch),
          onTap: openOrders,
        ),
      if (s.deliveryProblems > 0)
        _AttentionRow(
          icon: AppIcons.warningCircle,
          color: p.warningFg,
          label: l10n.attnDeliveryProblems,
          value: s.deliveryProblems,
          text: count(s.deliveryProblems),
          onTap: openOrders,
        ),
      if (s.cashToCollect > 0)
        _AttentionRow(
          icon: AppIcons.money,
          color: p.textSecondary,
          label: l10n.attnCashToCollect,
          value: s.cashToCollect,
          text: money(s.cashToCollect),
          onTap: openOrders,
        ),
      if (s.lowStock > 0)
        _AttentionRow(
          icon: AppIcons.trendDown,
          color: p.warningFg,
          label: l10n.attnLowStock,
          value: s.lowStock,
          text: count(s.lowStock),
          onTap: openProducts,
        ),
    ];

    final attention = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.needsAttention),
        if (s.allCaughtUp)
          RowGroup(
            children: [
              NavRow(
                label: l10n.allCaughtUp,
                icon: AppIcons.checkCircle,
                iconColor: p.successFg,
              ),
            ],
          )
        else
          RowGroup(children: rows),
      ],
    );
    final soFar = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.todaySoFar),
        RowGroup(
          children: [
            _SummaryRow(
              label: l10n.todayApproved,
              text: count(s.approvedToday),
            ),
            _SummaryRow(
              label: l10n.todayDelivered,
              text: count(s.deliveredToday),
            ),
            _SummaryRow(
              label: l10n.todayValueApproved,
              text: money(s.valueApprovedToday),
            ),
          ],
        ),
      ],
    );

    final twoColumns = WindowClass.of(context).usesListDetail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.isSample) ...[
          const SampleDataBanner(),
          const SizedBox(height: Space.s24),
        ],
        if (twoColumns)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: attention),
              const SizedBox(width: Space.s24),
              Expanded(child: soFar),
            ],
          )
        else ...[
          attention,
          const SizedBox(height: Space.s24),
          soFar,
        ],
      ],
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.text,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final int value;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return NavRow(
      label: label,
      icon: icon,
      iconColor: color,
      onTap: onTap,
      semanticsLabel: context.l10n.attnRowSemantics(label, text),
      trailing: NumberRoll(
        value: value,
        text: text,
        style: context.type.numericBody.copyWith(
          color: context.palette.textPrimary,
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: LayoutTokens.rowMinHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.s12,
          vertical: Space.s12,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: context.type.body.copyWith(color: p.textSecondary),
              ),
            ),
            Text(
              text,
              style: context.type.numericBody.copyWith(color: p.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodaySkeleton extends StatelessWidget {
  const _TodaySkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SkeletonBlock(width: 120, height: 12),
          const SizedBox(height: Space.s8),
          for (var i = 0; i < 5; i++) ...[
            const SkeletonBlock(height: 56),
            const SizedBox(height: Space.s2),
          ],
        ],
      ),
    );
  }
}
