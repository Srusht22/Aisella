import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/backend/api.dart';
import '../../core/clock.dart';
import '../../core/formatting/bidi.dart';
import '../../core/formatting/dates.dart';
import '../../core/formatting/digits.dart';
import '../../core/l10n/l10n.dart';
import '../../core/settings/app_settings.dart';
import '../../design_system/components/app_button.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/components/rows.dart';
import '../../design_system/components/status.dart';
import '../../design_system/icons/app_icons.dart';
import '../../design_system/layout/responsive.dart';
import '../../design_system/motion/primitives.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../common/order_labels.dart' show orderNumber;
import '../common/top_level_page.dart';
import 'application/inbox_providers.dart';
import 'domain/conversation.dart';
import 'presentation/conversation_screen.dart';
import 'presentation/inbox_sheets.dart';
import 'presentation/inbox_text.dart';

/// Inbox (US-022): conversations the seller pasted in, newest activity
/// first, with status and source. No messaging channel is connected in this
/// release; nothing here implies one is.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windowClass = WindowClass.of(context);
    final list = _InboxList(listDetail: windowClass.usesListDetail);
    if (!windowClass.usesListDetail) return list;
    final selected = ref.watch(selectedConversationProvider);
    final p = context.palette;
    return Row(
      children: [
        SizedBox(width: 420, child: list),
        VerticalDivider(width: Strokes.hairline, color: p.borderHairline),
        Expanded(
          child: selected == null
              ? ColoredBox(
                  color: p.bgCanvas,
                  child: Center(
                    child: EmptyState(
                      icon: AppIcons.chatsCircle,
                      title: context.l10n.selectConversationHint,
                    ),
                  ),
                )
              : ConversationScreen(
                  key: ValueKey(selected),
                  conversationId: selected,
                  embedded: true,
                ),
        ),
      ],
    );
  }
}

Future<void> _newConversation(
  BuildContext context,
  WidgetRef ref, {
  required bool listDetail,
}) async {
  final id = await showNewConversationSheet(context);
  if (id == null || !context.mounted) return;
  if (listDetail) {
    ref.read(selectedConversationProvider.notifier).select(id);
  } else {
    await context.push(Routes.conversation(id));
  }
}

class _InboxList extends ConsumerWidget {
  const _InboxList({required this.listDetail});

  final bool listDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final inbox = ref.watch(inboxProvider);
    final filter = ref.watch(inboxFilterProvider);
    final digits = ref.watch(settingsProvider).digits;
    final page = inbox.value?.page;
    final rail = WindowClass.of(context).usesRail;

    String chipLabel(InboxFilter f) {
      final n = switch (f) {
        InboxFilter.needsYou => page?.needsYou,
        InboxFilter.needsReply => page?.needsReply,
        InboxFilter.waiting => page?.waiting,
        _ => null,
      };
      final label = inboxFilterLabel(l10n, f);
      return n == null || n == 0
          ? label
          : '$label · ${Bidi.ltr(Digits.display('$n', digits))}';
    }

    final Widget body = switch (inbox) {
      AsyncData(:final value)
          when value.page.items.isEmpty && filter == InboxFilter.open =>
        EmptyState(
          icon: AppIcons.chatsCircle,
          title: l10n.inboxEmptyTitle,
          body: l10n.inboxEmptyBody,
          action: AppButton(
            label: l10n.pasteConversation,
            icon: AppIcons.plus,
            onPressed: () =>
                _newConversation(context, ref, listDetail: listDetail),
          ),
        ),
      AsyncData(:final value) when value.page.items.isEmpty => EmptyState(
        icon: AppIcons.funnelSimple,
        title: l10n.inboxEmptyFilter,
      ),
      AsyncData(:final value) => _Rows(state: value, listDetail: listDetail),
      AsyncError(:final error) => ErrorState(
        cause: error is ApiException
            ? inboxErrorText(l10n, error)
            : l10n.errorServer,
        onRetry: () => ref.invalidate(inboxProvider),
      ),
      _ => const Padding(
        padding: EdgeInsets.all(Space.s24),
        child: Center(child: CircularProgressIndicator()),
      ),
    };

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 600) {
          ref.read(inboxProvider.notifier).loadMore();
        }
        return false;
      },
      child: TopLevelPage(
        title: l10n.navInbox,
        subtitle: l10n.inboxSubtitle,
        onRefresh: () async {
          ref.invalidate(inboxProvider);
          try {
            await ref.read(inboxProvider.future);
          } on Object {
            // The error state offers Retry.
          }
        },
        floatingActionButton: rail
            ? null
            : FloatingActionButton.extended(
                onPressed: () =>
                    _newConversation(context, ref, listDetail: listDetail),
                backgroundColor: context.palette.brandPrimary,
                foregroundColor: context.palette.textOnBrand,
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                icon: const Icon(AppIcons.plus, size: Sizes.iconMd),
                label: Text(
                  l10n.pasteConversation,
                  style: context.type.button.copyWith(
                    color: context.palette.textOnBrand,
                  ),
                ),
              ),
        slivers: [
          SliverToBoxAdapter(
            child: ContentWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (rail) ...[
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: AppButton(
                        label: l10n.pasteConversation,
                        icon: AppIcons.plus,
                        onPressed: () => _newConversation(
                          context,
                          ref,
                          listDetail: listDetail,
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.s12),
                  ],
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final f in InboxFilter.values)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(
                              end: Space.s8,
                            ),
                            child: ChoiceChip(
                              label: Text(chipLabel(f)),
                              selected: filter == f,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  ref.read(inboxFilterProvider.notifier).set(f),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s8),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(child: ContentWidth(child: body)),
        ],
      ),
    );
  }
}

class _Rows extends ConsumerWidget {
  const _Rows({required this.state, required this.listDetail});

  final InboxState state;
  final bool listDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final selected = listDetail
        ? ref.watch(selectedConversationProvider)
        : null;
    var index = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RowGroup(
          children: [
            for (final c in state.page.items)
              _ConversationRow(
                key: ValueKey(c.id),
                conversation: c,
                selected: c.id == selected,
                animate: index++ < 12,
                onTap: () => listDetail
                    ? ref
                          .read(selectedConversationProvider.notifier)
                          .select(c.id)
                    : context.push(Routes.conversation(c.id)),
              ),
          ],
        ),
        if (state.loadingMore)
          const Padding(
            padding: EdgeInsets.all(Space.s16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (state.moreFailed)
          AppButton(
            label: l10n.retry,
            variant: AppButtonVariant.tertiary,
            onPressed: () => ref.read(inboxProvider.notifier).loadMore(),
          ),
        const SizedBox(height: Space.s64),
      ],
    );
  }
}

/// Status badge of a conversation (icon + text, never colour alone).
class ConversationStatusBadge extends StatelessWidget {
  const ConversationStatusBadge(this.status, {super.key});

  final ConversationStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (IconData icon, Tone tone) = switch (status) {
      ConversationStatus.needsYou => (AppIcons.warning, Tone.danger),
      ConversationStatus.needsReply => (AppIcons.chatText, Tone.info),
      ConversationStatus.waiting => (
        AppIcons.clockCounterClockwise,
        Tone.neutral,
      ),
      ConversationStatus.closed => (AppIcons.checkCircle, Tone.neutral),
    };
    return StatusBadge(
      label: conversationStatusLabel(l10n, status),
      icon: icon,
      tone: tone,
    );
  }
}

class _ConversationRow extends ConsumerWidget {
  const _ConversationRow({
    super.key,
    required this.conversation,
    required this.onTap,
    this.selected = false,
    this.animate = false,
  });

  final ConversationSummary conversation;
  final VoidCallback onTap;
  final bool selected;
  final bool animate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final now = ref.watch(clockProvider)();
    final c = conversation;
    final name = c.customerLabel ?? l10n.unknownCustomer;
    final when = DateUtils.isSameDay(now, c.lastActivityAt)
        ? Dates.time(c.lastActivityAt, digits: digits)
        : Dates.dayMonthYear(
            c.lastActivityAt,
            locale: Localizations.localeOf(context),
            digits: digits,
          );
    final preview = c.lastPreview == null
        ? null
        : '${c.lastInbound ? '' : l10n.previewYou} ${Bidi.auto(c.lastPreview!)}'
              .trim();
    final reasons = c.escalationReasons
        .map((r) => escalationLabel(l10n, r))
        .join(', ');

    final row = Semantics(
      button: true,
      selected: selected,
      label: [
        name,
        sourceLabel(l10n, c.source),
        conversationStatusLabel(l10n, c.status),
        if (reasons.isNotEmpty) reasons,
        ?preview,
        when,
      ].join(', '),
      excludeSemantics: true,
      child: Material(
        color: selected ? p.bgBrandWeak : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.s12,
                vertical: Space.s8,
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
                              Bidi.auto(name),
                              style: type.bodyStrong.copyWith(
                                color: p.textPrimary,
                              ),
                            ),
                            ConversationStatusBadge(c.status),
                          ],
                        ),
                        const SizedBox(height: Space.s4),
                        if (preview != null)
                          Text(
                            preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: type.body.copyWith(color: p.textSecondary),
                          ),
                        if (reasons.isNotEmpty)
                          Text(
                            reasons,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: type.caption.copyWith(color: p.dangerFgOnBg),
                          ),
                        const SizedBox(height: Space.s2),
                        Text(
                          [
                            sourceLabel(l10n, c.source),
                            if (c.order != null)
                              l10n.orderTitle(orderNumber(c.order!.number)),
                            if (c.aiPaused) l10n.aiPausedShort,
                          ].join(' · '),
                          style: type.caption.copyWith(color: p.textTertiary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.s8),
                  Text(
                    when,
                    style: type.caption.copyWith(color: p.textTertiary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return animate ? FadeSlideIn(child: row) : row;
  }
}
