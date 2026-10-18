import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../channels/application/channel_providers.dart';
import '../../channels/domain/channel.dart';
import '../../common/channel_labels.dart';
import '../../common/form_widgets.dart';
import '../../orders/domain/order.dart' show OrderStatus;
import '../domain/conversation.dart';

/// The longest text the app offers to send; the server applies each
/// provider's own limit (for example 1,999 for Messenger).
const maxLiveMessage = 4000;

/// The top of a live conversation: which account it arrived on, and why
/// replies cannot be sent when they cannot.
class LiveChannelHeader extends StatelessWidget {
  const LiveChannelHeader({super.key, required this.channel});

  final ConversationChannel channel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final ch = channel;
    final account = Bidi.auto(ch.accountName ?? ch.providerName);
    final (tone, icon) = connectionStateStyle(ch.uiState);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            StatusBadge(
              label: ch.providerName,
              icon: AppIcons.chatsCircle,
              tone: Tone.info,
            ),
            if (ch.uiState != ConnectionUiState.connected)
              StatusBadge(
                label: connectionStateLabel(l10n, ch.uiState),
                icon: icon,
                tone: tone,
              ),
          ],
        ),
        const SizedBox(height: Space.s4),
        Text(
          l10n.liveNote(account),
          style: type.caption.copyWith(color: p.textTertiary),
        ),
        if (ch.contactBlocked) ...[
          const SizedBox(height: Space.s12),
          AppBanner(
            tone: Tone.neutral,
            icon: AppIcons.prohibit,
            title: l10n.errContactUnavailable,
          ),
        ] else if (!ch.canSend) ...[
          const SizedBox(height: Space.s12),
          AppBanner(
            tone: Tone.warning,
            icon: AppIcons.cloudSlash,
            title: l10n.liveCannotSend,
            body: connectionStateBody(l10n, ch.uiState),
          ),
        ] else if (!ch.windowOpen) ...[
          const SizedBox(height: Space.s12),
          Semantics(
            liveRegion: true,
            child: AppBanner(
              tone: Tone.warning,
              icon: AppIcons.clockCounterClockwise,
              title: l10n.windowClosedTitle,
              body: ch.templates
                  ? l10n.windowClosedTemplates
                  : l10n.windowClosedBody,
            ),
          ),
        ],
      ],
    );
  }
}

/// Delivery of one message sent through a channel, and what the seller can
/// do about it: cancel while queued, decide an unknown outcome.
class DeliveryLine extends ConsumerStatefulWidget {
  const DeliveryLine({
    super.key,
    required this.conversationId,
    required this.message,
  });

  final String conversationId;
  final Message message;

  @override
  ConsumerState<DeliveryLine> createState() => _DeliveryLineState();
}

class _DeliveryLineState extends ConsumerState<DeliveryLine> {
  final _intent = IntentKey();
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action();
    } on ApiException catch (e) {
      showSnackOn(messenger, channelErrorText(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendAgain(SendInfo send) async {
    final l10n = context.l10n;
    final ok = await showConfirmDialog(
      context: context,
      title: l10n.sendAgainTitle,
      body: l10n.sendAgainBody,
      confirmLabel: l10n.sendAgain,
      cancelLabel: l10n.cancel,
    );
    if (!ok || !mounted) return;
    await _run(
      () => ref
          .read(channelActionsProvider)
          .resolveUnknown(
            widget.conversationId,
            send,
            'send_again',
            idempotencyKey: _intent.forPayload('${send.id}|send_again'),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final m = widget.message;
    final d = m.delivery;
    final send = m.send;
    if (d == null) return const SizedBox.shrink();
    final (tone, icon) = deliveryStyle(d);
    final retrying =
        send != null && send.state == 'queued' && send.attempts > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Space.s4),
        Semantics(
          liveRegion: true,
          child: StatusBadge(
            label: deliveryLabel(l10n, d),
            icon: icon,
            tone: tone,
          ),
        ),
        if (retrying) ...[
          const SizedBox(height: Space.s4),
          Text(
            l10n.deliveryRetrying,
            style: type.caption.copyWith(color: p.textSecondary),
          ),
        ],
        if (d == DeliveryState.failed) ...[
          const SizedBox(height: Space.s4),
          Text(
            sendFailureText(l10n, send?.errorCode),
            style: type.caption.copyWith(color: p.dangerFg),
          ),
        ],
        if (send != null && send.canResolve) ...[
          const SizedBox(height: Space.s4),
          Text(
            l10n.unknownBody,
            style: type.caption.copyWith(color: p.warningFg),
          ),
          Wrap(
            spacing: Space.s8,
            children: [
              AppButton(
                label: l10n.markArrived,
                icon: AppIcons.check,
                variant: AppButtonVariant.tertiary,
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => ref
                            .read(channelActionsProvider)
                            .resolveUnknown(
                              widget.conversationId,
                              send,
                              'mark_sent',
                              idempotencyKey: _intent.forPayload(
                                '${send.id}|mark_sent',
                              ),
                            ),
                      ),
              ),
              AppButton(
                label: l10n.sendAgain,
                icon: AppIcons.arrowClockwise,
                variant: AppButtonVariant.tertiary,
                onPressed: _busy ? null : () => _sendAgain(send),
              ),
            ],
          ),
        ],
        if (send != null && send.canCancel)
          AppButton(
            label: l10n.cancelSending,
            icon: AppIcons.x,
            variant: AppButtonVariant.tertiary,
            onPressed: _busy
                ? null
                : () => _run(
                    () => ref
                        .read(channelActionsProvider)
                        .cancel(widget.conversationId, send),
                  ),
          ),
      ],
    );
  }
}

/// The seller's explicit authorization: the exact text, the channel, and a
/// deliberate "Send". Returns true only if the seller confirmed.
Future<bool> confirmSend(
  BuildContext context, {
  required String text,
  required String providerName,
}) async {
  final l10n = context.l10n;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final p = context.palette;
      return AlertDialog(
        title: Text(l10n.sendConfirmTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.sendConfirmBody(providerName)),
              const SizedBox(height: Space.s12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: p.bgSunken,
                  border: Border.all(
                    color: p.borderHairline,
                    width: Strokes.hairline,
                  ),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(Space.s12),
                  // Exactly what will be sent: no trimming, no formatting.
                  child: SelectableText(
                    text,
                    key: const ValueKey('send-confirm-text'),
                    textDirection: Bidi.detect(text) ?? TextDirection.ltr,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          AppButton(
            label: l10n.cancel,
            variant: AppButtonVariant.tertiary,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          AppButton(
            label: l10n.sendAction,
            icon: AppIcons.arrowRight,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Reply box of a live conversation. Nothing is sent until the seller
/// confirms the exact text in [confirmSend].
class LiveComposer extends ConsumerStatefulWidget {
  const LiveComposer({
    super.key,
    required this.conversation,
    required this.controller,
    this.suggestionId,
    this.onSent,
  });

  final Conversation conversation;
  final TextEditingController controller;

  /// The AI suggestion the text started from (recorded with the send).
  final String? suggestionId;
  final VoidCallback? onSent;

  @override
  ConsumerState<LiveComposer> createState() => _LiveComposerState();
}

class _LiveComposerState extends ConsumerState<LiveComposer> {
  final _intent = IntentKey();
  bool _sending = false;
  String? _error;

  Future<void> _send() async {
    final l10n = context.l10n;
    final ch = widget.conversation.summary.channel!;
    // What the seller sees is what is sent: only outer blank lines removed.
    final text = widget.controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = l10n.errMessageRequired);
      return;
    }
    if (text.length > maxLiveMessage) {
      setState(() => _error = l10n.errMessageTooLong);
      return;
    }
    final ok = await confirmSend(
      context,
      text: text,
      providerName: ch.providerName,
    );
    if (!ok || !mounted) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref
          .read(channelActionsProvider)
          .send(
            widget.conversation.id,
            text,
            suggestionId: widget.suggestionId,
            idempotencyKey: _intent.forPayload('${widget.suggestionId}|$text'),
          );
      _intent.reset();
      widget.controller.clear();
      widget.onSent?.call();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = channelErrorText(l10n, e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final ch = widget.conversation.summary.channel!;
    final canWrite = ch.canSend && ch.windowOpen && !ch.contactBlocked;
    final canTemplate =
        ch.canSend && !ch.windowOpen && ch.templates && !ch.contactBlocked;
    return Material(
      color: p.bgSurface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            Space.s16,
            Space.s8,
            Space.s16,
            Space.s8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                FormErrorBanner(message: _error!),
                const SizedBox(height: Space.s8),
              ],
              if (canWrite)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: AppTextField(
                        key: const ValueKey('live-composer'),
                        label: l10n.composerLabel,
                        controller: widget.controller,
                        maxLines: 4,
                        enabled: !_sending,
                        keyboardType: TextInputType.multiline,
                      ),
                    ),
                    const SizedBox(width: Space.s8),
                    AppButton(
                      label: l10n.sendAction,
                      icon: AppIcons.arrowRight,
                      loading: _sending,
                      loadingLabel: l10n.deliverySending,
                      onPressed: _sending ? null : _send,
                    ),
                  ],
                )
              else if (canTemplate)
                AppButton(
                  label: l10n.templatesAction,
                  icon: AppIcons.chatText,
                  expand: true,
                  onPressed: () =>
                      showTemplateSheet(context, widget.conversation),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Approved templates for a conversation whose window is closed.
Future<void> showTemplateSheet(
  BuildContext context,
  Conversation conversation,
) => showAppSheet<void>(
  context: context,
  title: context.l10n.templatesTitle,
  builder: (_) => _TemplatePicker(conversation: conversation),
);

class _TemplatePicker extends ConsumerStatefulWidget {
  const _TemplatePicker({required this.conversation});

  final Conversation conversation;

  @override
  ConsumerState<_TemplatePicker> createState() => _TemplatePickerState();
}

class _TemplatePickerState extends ConsumerState<_TemplatePicker> {
  final _intent = IntentKey();
  MessageTemplate? _selected;
  List<TextEditingController> _params = [];
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _params) {
      c.dispose();
    }
    super.dispose();
  }

  void _select(MessageTemplate t) {
    for (final c in _params) {
      c.dispose();
    }
    setState(() {
      _selected = t;
      _params = [
        for (var i = 0; i < t.paramCount; i++) TextEditingController(),
      ];
      _error = null;
    });
  }

  Future<void> _send() async {
    final l10n = context.l10n;
    final t = _selected!;
    final values = [for (final c in _params) c.text.trim()];
    if (!values.every(MessageTemplate.paramOk)) {
      setState(() => _error = l10n.templateParamInvalid);
      return;
    }
    final ok = await confirmSend(
      context,
      text: t.render(values),
      providerName: widget.conversation.summary.channel!.providerName,
    );
    if (!ok || !mounted) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref
          .read(channelActionsProvider)
          .sendTemplate(
            widget.conversation.id,
            t,
            values,
            idempotencyKey: _intent.forPayload(
              '${t.id}|${values.join('\u0000')}',
            ),
          );
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = channelErrorText(l10n, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final list = ref.watch(templatesProvider(widget.conversation.id));
    return switch (list) {
      AsyncError(:final error) => FormErrorBanner(
        message: error is ApiException
            ? channelErrorText(l10n, error)
            : l10n.errorServer,
      ),
      AsyncData(:final value) when value.items.isEmpty => Text(
        l10n.templatesNone,
        style: type.body.copyWith(color: p.textSecondary),
      ),
      AsyncData(:final value) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.templatesHelp,
            style: type.label.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: Space.s12),
          if (_error != null) ...[
            FormErrorBanner(message: _error!),
            const SizedBox(height: Space.s12),
          ],
          for (final t in value.items)
            RadioListTile<String>(
              value: t.id,
              // ignore: deprecated_member_use
              groupValue: _selected?.id,
              // ignore: deprecated_member_use
              onChanged: _sending ? null : (_) => _select(t),
              title: Text(t.name, textDirection: TextDirection.ltr),
              subtitle: Text(
                Bidi.auto(t.body),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_selected case final t?) ...[
            const SizedBox(height: Space.s12),
            for (var i = 0; i < _params.length; i++) ...[
              AppTextField(
                key: ValueKey('template-param-$i'),
                label: l10n.templateParam(i + 1),
                controller: _params[i],
                enabled: !_sending,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: Space.s8),
            ],
            Text(l10n.previewLabel, style: type.label),
            const SizedBox(height: Space.s4),
            Text(
              Bidi.auto(t.render([for (final c in _params) c.text.trim()])),
              style: type.body.copyWith(color: p.textPrimary),
            ),
            const SizedBox(height: Space.s16),
            AppButton(
              label: l10n.sendAction,
              icon: AppIcons.arrowRight,
              loading: _sending,
              expand: true,
              onPressed: _sending ? null : _send,
            ),
          ],
        ],
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// Sends the server-generated confirmation of an approved order through the
/// conversation's channel (the text is generated and checked by the server).
class SendOrderConfirmationButton extends ConsumerStatefulWidget {
  const SendOrderConfirmationButton({
    super.key,
    required this.conversation,
    required this.language,
  });

  final Conversation conversation;

  /// ckb, ar or en: the customer's language.
  final String language;

  @override
  ConsumerState<SendOrderConfirmationButton> createState() =>
      _SendOrderConfirmationButtonState();
}

class _SendOrderConfirmationButtonState
    extends ConsumerState<SendOrderConfirmationButton> {
  final _intent = IntentKey();
  bool _busy = false;

  static bool applies(Conversation c) {
    final o = c.order;
    final ch = c.summary.channel;
    return o != null &&
        ch != null &&
        ch.canSend &&
        ch.windowOpen &&
        !o.isTest &&
        const {
          OrderStatus.approved,
          OrderStatus.processing,
          OrderStatus.dispatched,
        }.contains(o.status);
  }

  Future<void> _send() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final c = widget.conversation;
    final actions = ref.read(channelActionsProvider);
    setState(() => _busy = true);
    try {
      final text = await actions.confirmationText(c.order!.id, widget.language);
      if (!mounted) return;
      // No spinner while the seller reads the text and decides.
      setState(() => _busy = false);
      final ok = await confirmSend(
        context,
        text: text,
        providerName: c.summary.channel!.providerName,
      );
      if (!ok || !mounted) return;
      setState(() => _busy = true);
      await actions.send(
        c.id,
        text,
        kind: 'order_confirmation',
        orderId: c.order!.id,
        idempotencyKey: _intent.forPayload('${c.order!.id}|$text'),
      );
      showSnackOn(messenger, l10n.confirmationQueued);
    } on ApiException catch (e) {
      showSnackOn(messenger, channelErrorText(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!applies(widget.conversation)) return const SizedBox.shrink();
    return AppButton(
      label: context.l10n.sendOrderConfirmation,
      icon: AppIcons.sealCheck,
      variant: AppButtonVariant.secondary,
      loading: _busy,
      onPressed: _busy ? null : _send,
    );
  }
}
