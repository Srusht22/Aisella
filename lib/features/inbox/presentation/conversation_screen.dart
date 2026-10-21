import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/order_labels.dart';
import '../../orders/domain/order.dart' show OrderStatus;
import '../application/inbox_providers.dart';
import '../domain/conversation.dart';
import 'inbox_sheets.dart';
import 'inbox_text.dart';
import 'live_conversation.dart';

/// One conversation (Phase 1 US-020–028): the pasted messages, the AI's
/// suggested reply (never sent by Aisellia), escalation, and the AI draft.
/// Live conversations (Phase 9) add a reply box: "Use this reply" puts the
/// suggestion there, and nothing is sent until the seller confirms the exact
/// text; each sent message shows its delivery.
/// Four levels are kept apart on screen (Phase 3 AI §10): a suggestion is
/// "not sent", a draft is "not confirmed", approval happens only on the order
/// screen, and a copied reply is "not confirmed as sent" until the seller
/// says they sent it.
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversationId,
    this.embedded = false,
  });

  final String conversationId;

  /// Shown as the detail pane of the tablet list–detail layout.
  final bool embedded;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  bool _running = false;

  /// Live conversations: the reply being written, and the suggestion it
  /// started from.
  final _composer = TextEditingController();
  String? _composerSuggestionId;

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  void _useReply(Suggestion s) {
    if (s.text == null) return;
    setState(() {
      _composer.text = s.text!;
      _composerSuggestionId = s.id;
    });
    showSnackOn(ScaffoldMessenger.of(context), context.l10n.replyInComposer);
  }

  /// The latest failure of this screen's AI request, until the next success.
  String? _aiError;

  Future<void> _assist({bool draft = false}) async {
    final l10n = context.l10n;
    setState(() {
      _running = true;
      _aiError = null;
    });
    try {
      final outcome = await ref
          .read(inboxActionsProvider)
          .assist(
            widget.conversationId,
            draft: draft,
            // A new tap is a new intent; a lost answer is replayed with this key.
            idempotencyKey: newIdempotencyKey(),
          );
      if (!mounted) return;
      setState(() {
        _running = false;
        _aiError = outcome.status.failed
            ? runFailureText(l10n, outcome.status)
            : null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _aiError = e.outcomeUnknown
            ? l10n.aiStillWorking
            : inboxErrorText(l10n, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final conversation = ref.watch(conversationProvider(widget.conversationId));
    final value = conversation.value;

    final Widget body = switch (conversation) {
      AsyncData(:final value) => _Body(
        conversation: value,
        running: _running,
        aiError: _aiError,
        onRetry: _assist,
        onUseReply: _useReply,
      ),
      AsyncError(:final error) =>
        error is ApiException && error.code == ApiErrorCode.notFound
            ? EmptyState(
                icon: AppIcons.chatsCircle,
                title: l10n.conversationUnavailable,
              )
            : ErrorState(
                cause: error is ApiException
                    ? inboxErrorText(l10n, error)
                    : l10n.errorServer,
                onRetry: () =>
                    ref.invalidate(conversationProvider(widget.conversationId)),
              ),
      _ => const Center(child: CircularProgressIndicator()),
    };

    final canAssist =
        value != null &&
        value.aiEnabled &&
        !value.summary.aiPaused &&
        value.hasCustomerMessage;
    return Scaffold(
      backgroundColor: p.bgCanvas,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text(
          value == null
              ? ''
              : Bidi.auto(value.summary.customerLabel ?? l10n.unknownCustomer),
        ),
        actions: [if (value != null) _Menu(conversation: value)],
      ),
      body: AnimatedSwitcher(
        duration: Motion.fade(context, MotionTokens.sm),
        child: KeyedSubtree(key: ValueKey(conversation.hasValue), child: body),
      ),
      bottomNavigationBar: value == null
          ? null
          : _withComposer(
              value,
              StickyActionBar(
                reason: canAssist
                    ? null
                    : Text(
                        !value.aiEnabled
                            ? l10n.errAiDisabled
                            : value.summary.aiPaused
                            ? l10n.errAiPaused
                            : l10n.errNothingToAnswer,
                        style: context.type.caption.copyWith(
                          color: p.textSecondary,
                        ),
                      ),
                secondary: AppButton(
                  label: l10n.prepareDraft,
                  variant: AppButtonVariant.secondary,
                  icon: AppIcons.receipt,
                  onPressed: canAssist && !_running
                      ? () => _assist(draft: true)
                      : null,
                ),
                primary: AppButton(
                  label: value.suggestion == null
                      ? l10n.getSuggestion
                      : l10n.suggestAgain,
                  icon: AppIcons.sparkle,
                  loading: _running,
                  loadingLabel: l10n.aiWorking,
                  onPressed: canAssist && !_running ? _assist : null,
                ),
              ),
            ),
    );
  }

  /// Live conversations: the reply box above the assistant's actions.
  Widget _withComposer(Conversation c, Widget actions) => !c.summary.isLive
      ? Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [const _ConnectToReply(), actions],
        )
      : Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LiveComposer(
              conversation: c,
              controller: _composer,
              suggestionId: _composerSuggestionId,
              onSent: () => setState(() => _composerSuggestionId = null),
            ),
            actions,
          ],
        );
}

enum _MenuItem { add, reply, pause, resume, close, reopen, delete }

class _Menu extends ConsumerWidget {
  const _Menu({required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final c = conversation.summary;
    final actions = ref.read(inboxActionsProvider);
    final messenger = ScaffoldMessenger.of(context);
    final items = <(_MenuItem, String, IconData)>[
      // Live conversations receive and send through the channel itself.
      if (!c.isLive) ...[
        (_MenuItem.add, l10n.addMessages, AppIcons.plus),
        (_MenuItem.reply, l10n.recordMyReply, AppIcons.chatText),
      ],
      if (c.aiPaused)
        (_MenuItem.resume, l10n.resumeAi, AppIcons.sparkle)
      else
        (_MenuItem.pause, l10n.pauseAi, AppIcons.prohibit),
      if (c.status == ConversationStatus.closed)
        (_MenuItem.reopen, l10n.reopenConversation, AppIcons.arrowClockwise)
      else
        (_MenuItem.close, l10n.closeConversation, AppIcons.checkCircle),
      (_MenuItem.delete, l10n.deleteConversation, AppIcons.trash),
    ];

    Future<void> run(Future<void> Function() f) async {
      try {
        await f();
      } on ApiException catch (e) {
        showSnackOn(messenger, inboxErrorText(l10n, e));
      }
    }

    return PopupMenuButton<_MenuItem>(
      tooltip: l10n.moreActions,
      icon: const Icon(AppIcons.dotsThree),
      onSelected: (m) async {
        switch (m) {
          case _MenuItem.add:
            await showAddMessageSheet(context, conversation.id);
          case _MenuItem.reply:
            await showRecordReplySheet(context, conversation.id);
          case _MenuItem.pause:
            await run(() => actions.update(conversation, aiPaused: true));
          case _MenuItem.resume:
            await run(() => actions.update(conversation, aiPaused: false));
          case _MenuItem.close:
            await run(
              () => actions.update(
                conversation,
                status: ConversationStatus.closed,
              ),
            );
          case _MenuItem.reopen:
            await run(
              () => actions.update(
                conversation,
                status: ConversationStatus.needsReply,
              ),
            );
          case _MenuItem.delete:
            final ok = await showConfirmDialog(
              context: context,
              title: l10n.deleteConversationTitle,
              body: l10n.deleteConversationBody,
              confirmLabel: l10n.delete,
              cancelLabel: l10n.cancel,
              destructive: true,
            );
            if (!ok) return;
            await run(() => actions.delete(conversation.id));
            if (context.mounted && Navigator.of(context).canPop()) {
              context.pop();
            }
        }
      },
      itemBuilder: (_) => [
        for (final (m, label, icon) in items)
          PopupMenuItem(
            value: m,
            child: Row(
              children: [
                Icon(icon, size: Sizes.iconMd),
                const SizedBox(width: Space.s12),
                Flexible(child: Text(label)),
              ],
            ),
          ),
      ],
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({
    required this.conversation,
    required this.running,
    required this.aiError,
    required this.onRetry,
    required this.onUseReply,
  });

  final Conversation conversation;
  final bool running;
  final String? aiError;
  final VoidCallback onRetry;
  final ValueChanged<Suggestion> onUseReply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final c = conversation.summary;
    final suggestion = conversation.suggestion;
    final lastRun = conversation.lastRun;
    // A failed run newer than the suggestion explains why nothing new came.
    final runFailed =
        lastRun != null &&
        lastRun.status.failed &&
        (suggestion == null || !running);

    return ListView(
      padding: const EdgeInsets.only(bottom: Space.s24),
      children: [
        ContentWidth(
          maxWidth: LayoutTokens.maxWidthForm,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: Space.s12),
              if (c.isSandbox) ...[
                AppBanner(
                  tone: Tone.warning,
                  icon: AppIcons.flask,
                  title: l10n.sandboxBanner,
                ),
                const SizedBox(height: Space.s12),
              ],
              if (c.channel case final channel?)
                LiveChannelHeader(channel: channel)
              else
                Text(
                  c.isSandbox
                      ? l10n.sandboxNote
                      : l10n.importedNote(sourceLabel(l10n, c.source)),
                  style: type.caption.copyWith(color: p.textTertiary),
                ),
              if (c.status == ConversationStatus.needsYou) ...[
                const SizedBox(height: Space.s12),
                Semantics(
                  liveRegion: true,
                  child: AppBanner(
                    tone: Tone.danger,
                    icon: AppIcons.warning,
                    title: l10n.convNeedsYou,
                    body: c.escalationReasons
                        .map((r) => escalationLabel(l10n, r))
                        .join('\n'),
                    action: AppButton(
                      label: l10n.markHandled,
                      variant: AppButtonVariant.tertiary,
                      onPressed: () => ref
                          .read(inboxActionsProvider)
                          .update(
                            conversation,
                            status: ConversationStatus.needsReply,
                          ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: Space.s16),
              for (final m in conversation.messages)
                _MessageBubble(conversationId: conversation.id, message: m),
              if (conversation.order case final order?) ...[
                const SizedBox(height: Space.s16),
                SectionHeader(l10n.sectionAiDraft),
                RowGroup(
                  children: [
                    FieldRow(
                      label: l10n.orderTitle(orderNumber(order.number)),
                      value: Text(
                        order.status == OrderStatus.draft ||
                                order.status == OrderStatus.pendingApproval
                            ? l10n.aiDraftNotConfirmed(
                                statusLabel(l10n, order.status),
                              )
                            : statusLabel(l10n, order.status),
                      ),
                      caption: order.issues.isEmpty
                          ? (order.total == null
                                ? null
                                : Text(
                                    money(
                                      context,
                                      order.total!,
                                      order.currency,
                                      digits,
                                    ),
                                    style: type.caption,
                                  ))
                          : Text(
                              order.issues
                                  .map((i) => issueText(l10n, i))
                                  .join(' · '),
                              style: type.caption.copyWith(color: p.warningFg),
                            ),
                      trailing: const Icon(AppIcons.caretRight),
                      onTap: () => context.push(Routes.order(order.id)),
                    ),
                  ],
                ),
                if (c.isLive) ...[
                  const SizedBox(height: Space.s8),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SendOrderConfirmationButton(
                      conversation: conversation,
                      language: suggestion?.language ?? 'ckb',
                    ),
                  ),
                ],
              ],
              const SizedBox(height: Space.s16),
              SectionHeader(l10n.sectionAiAssistant),
              if (!conversation.aiEnabled)
                AppBanner(
                  tone: Tone.neutral,
                  icon: AppIcons.prohibit,
                  title: l10n.errAiDisabled,
                  action: AppButton(
                    label: l10n.aiSettings,
                    variant: AppButtonVariant.tertiary,
                    onPressed: () => context.push(Routes.storeAi),
                  ),
                )
              else if (running)
                Semantics(
                  liveRegion: true,
                  child: AppBanner(
                    tone: Tone.info,
                    icon: AppIcons.sparkle,
                    title: l10n.aiWorking,
                    body: l10n.aiWorkingBody,
                  ),
                )
              else if (aiError != null || runFailed)
                AppBanner(
                  tone: Tone.warning,
                  icon: AppIcons.cloudSlash,
                  title: aiError ?? runFailureText(l10n, lastRun!.status),
                  body: l10n.aiManualPath,
                  action: AppButton(
                    label: l10n.retry,
                    variant: AppButtonVariant.tertiary,
                    onPressed: onRetry,
                  ),
                ),
              if (suggestion != null && !running) ...[
                const SizedBox(height: Space.s12),
                _SuggestionCard(
                  conversationId: conversation.id,
                  suggestion: suggestion,
                  live: c.isLive,
                  onUse: c.channel?.canSend == true && c.channel!.windowOpen
                      ? () => onUseReply(suggestion)
                      : null,
                ),
              ],
              const SizedBox(height: Space.s12),
              Text(
                l10n.aiUsage(
                  Bidi.ltr(
                    Digits.display('${conversation.callsToday}', digits),
                  ),
                  Bidi.ltr(
                    Digits.display('${conversation.dailyLimit}', digits),
                  ),
                ),
                style: type.caption.copyWith(color: p.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({required this.conversationId, required this.message});

  final String conversationId;
  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final m = message;
    final label = messageStateLabel(l10n, m);
    final time = Dates.time(m.createdAt, digits: digits);
    final text = m.body == null ? l10n.messageRemoved : Bidi.auto(m.body!);
    return Align(
      alignment: m.inbound
          ? AlignmentDirectional.centerStart
          : AlignmentDirectional.centerEnd,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s4),
          child: Semantics(
            label:
                '${m.inbound ? l10n.fromCustomer : l10n.fromYou}, $label, $time',
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: m.inbound ? p.bgSurface : p.bgBrandWeak,
                border: Border.all(
                  color: p.borderHairline,
                  width: Strokes.hairline,
                ),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Padding(
                padding: const EdgeInsets.all(Space.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      text,
                      style: type.body.copyWith(
                        color: m.body == null ? p.textTertiary : p.textPrimary,
                      ),
                    ),
                    const SizedBox(height: Space.s4),
                    Text(
                      '$label · $time',
                      style: type.caption.copyWith(color: p.textTertiary),
                    ),
                    if (!m.inbound && m.delivery != null)
                      DeliveryLine(conversationId: conversationId, message: m),
                    if (m.state == MessageState.copied)
                      AppButton(
                        label: l10n.iSentThis,
                        icon: AppIcons.check,
                        variant: AppButtonVariant.tertiary,
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await ref
                                .read(inboxActionsProvider)
                                .markSent(conversationId, m.id);
                          } on ApiException catch (e) {
                            showSnackOn(messenger, inboxErrorText(l10n, e));
                          }
                        },
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
}

class _SuggestionCard extends ConsumerStatefulWidget {
  const _SuggestionCard({
    required this.conversationId,
    required this.suggestion,
    this.live = false,
    this.onUse,
  });

  final String conversationId;
  final Suggestion suggestion;

  /// Live conversation: the reply goes into the reply box (and is sent only
  /// after the seller confirms it) instead of being copied.
  final bool live;
  final VoidCallback? onUse;

  @override
  ConsumerState<_SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends ConsumerState<_SuggestionCard> {
  final _intent = IntentKey();
  bool _busy = false;

  Future<void> _copy(String text, {String? edited}) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      await ref
          .read(inboxActionsProvider)
          .copySuggestion(
            widget.conversationId,
            widget.suggestion,
            editedText: edited,
            idempotencyKey: _intent.forPayload('${widget.suggestion.id}|$text'),
          );
      showSnackOn(messenger, l10n.copiedPasteThenMark);
    } on ApiException catch (e) {
      showSnackOn(messenger, inboxErrorText(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final s = widget.suggestion;
    final text = s.text ?? l10n.messageRemoved;
    final copied = s.status == SuggestionStatus.copied;
    final holding = holdingReason(l10n, s);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.bgSurface,
        border: Border.all(color: p.borderPencil, width: Strokes.hairline),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: Space.s8,
              runSpacing: Space.s4,
              children: [
                StatusBadge(
                  label: copied && !widget.live
                      ? l10n.suggestionCopied
                      : l10n.suggestionNotSent,
                  icon: AppIcons.sparkle,
                  tone: Tone.pencil,
                ),
                if (s.escalated)
                  StatusBadge(
                    label: l10n.convNeedsYou,
                    icon: AppIcons.warning,
                    tone: Tone.danger,
                  ),
              ],
            ),
            const SizedBox(height: Space.s8),
            // The reply is in the customer's language, whatever the app's.
            Directionality(
              textDirection: s.rtl ? TextDirection.rtl : TextDirection.ltr,
              child: SelectableText(
                text,
                style: type.body.copyWith(color: p.textPrimary),
              ),
            ),
            if (holding != null) ...[
              const SizedBox(height: Space.s8),
              Text(holding, style: type.caption.copyWith(color: p.warningFg)),
            ],
            if (s.factsUsed.isNotEmpty) ...[
              const SizedBox(height: Space.s12),
              Text(
                l10n.basedOnStoreData,
                style: type.label.copyWith(color: p.textSecondary),
              ),
              const SizedBox(height: Space.s4),
              for (final f in s.factsUsed)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.s2),
                  child: Text(
                    '${factLabel(l10n, f)}: ${Bidi.auto(f.value ?? '')}',
                    style: type.caption.copyWith(color: p.textSecondary),
                  ),
                ),
            ],
            if (s.missingFields.isNotEmpty) ...[
              const SizedBox(height: Space.s8),
              Text(
                l10n.stillNeeded(
                  s.missingFields
                      .map((f) => missingFieldLabel(l10n, f))
                      .join(', '),
                ),
                style: type.caption.copyWith(color: p.textSecondary),
              ),
            ],
            if (s.conflicts.isNotEmpty) ...[
              const SizedBox(height: Space.s4),
              Text(
                l10n.conflictingDetails(
                  s.conflicts.map((f) => missingFieldLabel(l10n, f)).join(', '),
                ),
                style: type.caption.copyWith(color: p.warningFg),
              ),
            ],
            const SizedBox(height: Space.s12),
            Wrap(
              spacing: Space.s8,
              runSpacing: Space.s8,
              children: [
                if (widget.live)
                  AppButton(
                    label: l10n.useThisReply,
                    icon: AppIcons.arrowUUpLeft,
                    onPressed: s.text == null ? null : widget.onUse,
                  )
                else ...[
                  AppButton(
                    label: l10n.copyReply,
                    icon: AppIcons.copy,
                    loading: _busy,
                    onPressed: _busy || s.text == null
                        ? null
                        : () => _copy(text),
                  ),
                  AppButton(
                    label: l10n.editBeforeCopy,
                    icon: AppIcons.pencilSimple,
                    variant: AppButtonVariant.secondary,
                    onPressed: _busy || s.text == null
                        ? null
                        : () async {
                            final edited = await showEditSuggestionSheet(
                              context,
                              text,
                            );
                            if (edited != null && mounted) {
                              await _copy(edited, edited: edited);
                            }
                          },
                  ),
                ],
                if (!copied)
                  AppButton(
                    label: l10n.dismiss,
                    variant: AppButtonVariant.tertiary,
                    onPressed: _busy
                        ? null
                        : () => ref
                              .read(inboxActionsProvider)
                              .dismiss(widget.conversationId, s),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown on conversations that did not arrive through a connected app:
/// replies are sent from Aisellia once the customer's app is connected.
class _ConnectToReply extends StatelessWidget {
  const _ConnectToReply();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    return Container(
      color: p.bgSunken,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.s16,
        vertical: Space.s8,
      ),
      child: Row(
        children: [
          Icon(AppIcons.info, size: Sizes.iconSm, color: p.textSecondary),
          const SizedBox(width: Space.s8),
          Expanded(
            child: Text(
              l10n.orderChatNotConnected,
              style: context.type.caption.copyWith(color: p.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => context.push(Routes.connections),
            child: Text(l10n.connectionsTitle),
          ),
        ],
      ),
    );
  }
}
