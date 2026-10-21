import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/route_guard.dart';
import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/motion/motion.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../channels/application/channel_providers.dart';
import '../../inbox/application/inbox_providers.dart';
import '../../inbox/domain/conversation.dart';

/// The customer chat an order came from, on the order itself: the latest
/// messages and a reply box. Replies go out through the connected channel
/// from inside the app; without a connection the seller is pointed to
/// Connections instead of another app.
class OrderChat extends ConsumerWidget {
  const OrderChat({super.key, required this.conversationId});

  final String conversationId;

  static const _shown = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final async = ref.watch(conversationProvider(conversationId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.orderChatTitle),
        AnimatedSwitcher(
          duration: Motion.fade(context, MotionTokens.md),
          child: switch (async) {
            AsyncData(:final value) => _Chat(
              key: const ValueKey('chat'),
              conversation: value,
              shown: _shown,
            ),
            AsyncError() => Text(
              l10n.orderChatUnavailable,
              key: const ValueKey('error'),
              style: type.body.copyWith(color: p.textSecondary),
            ),
            _ => const SizedBox(
              key: ValueKey('loading'),
              height: 96,
              child: Center(child: CircularProgressIndicator()),
            ),
          },
        ),
      ],
    );
  }
}

class _Chat extends ConsumerStatefulWidget {
  const _Chat({super.key, required this.conversation, required this.shown});

  final Conversation conversation;
  final int shown;

  @override
  ConsumerState<_Chat> createState() => _ChatState();
}

class _ChatState extends ConsumerState<_Chat> {
  final _text = TextEditingController();
  final _intent = IntentKey();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final l10n = context.l10n;
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      await ref
          .read(channelActionsProvider)
          .send(
            widget.conversation.id,
            text,
            idempotencyKey: _intent.forPayload(text),
          );
      _intent.reset();
      _text.clear();
      showSnackOn(messenger, l10n.orderChatSent);
    } on ApiException {
      showSnackOn(messenger, l10n.orderChatSendFailed);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final c = widget.conversation;
    final channel = c.summary.channel;
    final canReply = channel != null && channel.canSend && channel.windowOpen;
    final messages = c.messages.length > widget.shown
        ? c.messages.sublist(c.messages.length - widget.shown)
        : c.messages;

    return Container(
      padding: const EdgeInsets.all(Space.s12),
      decoration: BoxDecoration(
        color: p.bgSurface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: p.borderHairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.chatsCircle,
                size: Sizes.iconMd,
                color: p.textBrand,
              ),
              const SizedBox(width: Space.s8),
              Expanded(
                child: Text(
                  Bidi.auto(c.summary.customerLabel ?? l10n.orderChatCustomer),
                  style: type.bodyStrong.copyWith(color: p.textPrimary),
                ),
              ),
              if (channel != null)
                Text(
                  channel.providerName,
                  style: type.caption.copyWith(color: p.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: Space.s12),
          for (final (i, m) in messages.indexed) _Bubble(message: m, index: i),
          const SizedBox(height: Space.s8),
          if (canReply)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    enabled: !_sending,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: l10n.orderChatHint,
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: Space.s8),
                AnimatedScale(
                  scale: _text.text.trim().isEmpty ? 0.85 : 1,
                  duration: Motion.spatial(context, MotionTokens.sm),
                  curve: Curves.easeOutBack,
                  child: IconButton.filled(
                    tooltip: l10n.orderChatSend,
                    onPressed: _text.text.trim().isEmpty || _sending
                        ? null
                        : _send,
                    icon: _sending
                        ? const SizedBox.square(
                            dimension: Sizes.iconMd,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(AppIcons.arrowRight, size: Sizes.iconMd),
                  ),
                ),
              ],
            )
          else
            Text(
              channel == null
                  ? l10n.orderChatNotConnected
                  : l10n.orderChatWindowClosed(channel.providerName),
              style: type.caption.copyWith(color: p.textSecondary),
            ),
          const SizedBox(height: Space.s4),
          Wrap(
            spacing: Space.s8,
            children: [
              AppButton(
                label: l10n.orderChatOpen,
                icon: AppIcons.chatText,
                variant: AppButtonVariant.tertiary,
                onPressed: () => context.push(Routes.conversation(c.id)),
              ),
              if (channel == null)
                AppButton(
                  label: l10n.connectionsTitle,
                  icon: AppIcons.plus,
                  variant: AppButtonVariant.tertiary,
                  onPressed: () => context.push(Routes.connections),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One message; the latest ones fade and rise in, a little apart.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.index});

  final Message message;
  final int index;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    final inbound = message.inbound;
    final bubble = Align(
      alignment: inbound
          ? AlignmentDirectional.centerStart
          : AlignmentDirectional.centerEnd,
      child: Container(
        margin: const EdgeInsets.only(bottom: Space.s8),
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.s12,
          vertical: Space.s8,
        ),
        decoration: BoxDecoration(
          color: inbound ? p.bgSunken : p.bgBrandWeak,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Text(
          Bidi.auto(message.body ?? ''),
          style: type.body.copyWith(color: p.textPrimary),
        ),
      ),
    );
    if (Motion.reduced(context)) return bubble;
    final delay = 60 * index;
    final total = 260 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: MotionTokens.enter),
      child: bubble,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - v)),
          child: child,
        ),
      ),
    );
  }
}
