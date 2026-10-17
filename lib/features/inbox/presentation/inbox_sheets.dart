import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';
import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/form_widgets.dart';
import '../application/inbox_providers.dart';
import '../domain/conversation.dart';
import 'inbox_text.dart';

const _maxMessage = 4000;

/// US-020: paste a customer's message from Instagram, WhatsApp… or start a
/// sandbox test. Returns the new conversation's id.
Future<String?> showNewConversationSheet(BuildContext context) =>
    showAppSheet<String>(
      context: context,
      title: context.l10n.pasteConversation,
      builder: (_) => const _NewConversationForm(),
    );

/// More messages of the same conversation: the customer's, or a reply the
/// seller already sent elsewhere.
Future<bool?> showAddMessageSheet(
  BuildContext context,
  String conversationId,
) => showAppSheet<bool>(
  context: context,
  title: context.l10n.addMessages,
  builder: (_) => _AddMessageForm(conversationId: conversationId),
);

/// The seller's own reply, sent by them outside Aisellia.
Future<bool?> showRecordReplySheet(
  BuildContext context,
  String conversationId,
) => showAppSheet<bool>(
  context: context,
  title: context.l10n.recordMyReply,
  builder: (_) => _RecordReplyForm(conversationId: conversationId),
);

/// Edit a suggestion before copying it (US-024: the edited text is what is
/// recorded). Returns the text to copy, or null when cancelled.
Future<String?> showEditSuggestionSheet(BuildContext context, String text) =>
    showAppSheet<String>(
      context: context,
      title: context.l10n.editSuggestion,
      builder: (_) => _EditSuggestionForm(initial: text),
    );

class _NewConversationForm extends ConsumerStatefulWidget {
  const _NewConversationForm();

  @override
  ConsumerState<_NewConversationForm> createState() =>
      _NewConversationFormState();
}

class _NewConversationFormState extends ConsumerState<_NewConversationForm> {
  final _name = TextEditingController();
  final _text = TextEditingController();
  final _intent = IntentKey();
  ConversationSource _source = ConversationSource.instagram;
  bool _saving = false;
  String? _textError;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _textError = l10n.errMessageRequired);
      return;
    }
    if (text.length > _maxMessage) {
      setState(() => _textError = l10n.errMessageTooLong);
      return;
    }
    final label = _name.text.trim().isEmpty ? null : _name.text.trim();
    setState(() {
      _saving = true;
      _textError = null;
      _error = null;
    });
    try {
      final id = await ref
          .read(inboxActionsProvider)
          .create(
            source: _source,
            customerLabel: label,
            messages: [(inbound: true, body: text)],
            idempotencyKey: _intent.forPayload('${_source.name}|$label|$text'),
          );
      if (mounted) Navigator.of(context).pop(id);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = inboxErrorText(l10n, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.pasteConversationHelp,
          style: context.type.label.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: Space.s12),
        if (_error != null) ...[
          FormErrorBanner(message: _error!),
          const SizedBox(height: Space.s12),
        ],
        Text(l10n.fieldSource, style: context.type.label),
        const SizedBox(height: Space.s4),
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s8,
          children: [
            for (final s in ConversationSource.values)
              ChoiceChip(
                label: Text(sourceLabel(l10n, s)),
                selected: _source == s,
                showCheckmark: false,
                onSelected: _saving ? null : (_) => setState(() => _source = s),
              ),
          ],
        ),
        if (_source == ConversationSource.sandbox) ...[
          const SizedBox(height: Space.s8),
          Text(
            l10n.sandboxBanner,
            style: context.type.caption.copyWith(color: p.warningFg),
          ),
        ],
        const SizedBox(height: Space.s16),
        AppTextField(
          label: l10n.fieldCustomerLabel,
          helper: l10n.fieldCustomerLabelHelp,
          controller: _name,
          enabled: !_saving,
        ),
        const SizedBox(height: Space.s12),
        AppTextField(
          label: l10n.fieldCustomerMessage,
          controller: _text,
          maxLines: 6,
          error: _textError,
          enabled: !_saving,
          keyboardType: TextInputType.multiline,
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.saveConversation,
          loading: _saving,
          expand: true,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

class _AddMessageForm extends ConsumerStatefulWidget {
  const _AddMessageForm({required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<_AddMessageForm> createState() => _AddMessageFormState();
}

class _AddMessageFormState extends ConsumerState<_AddMessageForm> {
  final _text = TextEditingController();
  final _intent = IntentKey();
  bool _fromCustomer = true;
  bool _saving = false;
  String? _textError;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final text = _text.text.trim();
    if (text.isEmpty || text.length > _maxMessage) {
      setState(
        () => _textError = text.isEmpty
            ? l10n.errMessageRequired
            : l10n.errMessageTooLong,
      );
      return;
    }
    setState(() {
      _saving = true;
      _textError = null;
      _error = null;
    });
    try {
      await ref.read(inboxActionsProvider).importMessages(
        widget.conversationId,
        [(inbound: _fromCustomer, body: text)],
        idempotencyKey: _intent.forPayload('$_fromCustomer|$text'),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = inboxErrorText(l10n, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          FormErrorBanner(message: _error!),
          const SizedBox(height: Space.s12),
        ],
        AppSegmented<bool>(
          options: [(true, l10n.fromCustomer), (false, l10n.fromMeAlreadySent)],
          selected: _fromCustomer,
          onChanged: (v) => setState(() => _fromCustomer = v),
        ),
        const SizedBox(height: Space.s12),
        AppTextField(
          label: _fromCustomer
              ? l10n.fieldCustomerMessage
              : l10n.fieldYourEarlierReply,
          controller: _text,
          maxLines: 6,
          error: _textError,
          enabled: !_saving,
          keyboardType: TextInputType.multiline,
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.addMessage,
          loading: _saving,
          expand: true,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

class _RecordReplyForm extends ConsumerStatefulWidget {
  const _RecordReplyForm({required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<_RecordReplyForm> createState() => _RecordReplyFormState();
}

class _RecordReplyFormState extends ConsumerState<_RecordReplyForm> {
  final _text = TextEditingController();
  final _intent = IntentKey();
  bool _saving = false;
  String? _textError;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final text = _text.text.trim();
    if (text.isEmpty || text.length > _maxMessage) {
      setState(
        () => _textError = text.isEmpty
            ? l10n.errMessageRequired
            : l10n.errMessageTooLong,
      );
      return;
    }
    setState(() {
      _saving = true;
      _textError = null;
      _error = null;
    });
    try {
      await ref
          .read(inboxActionsProvider)
          .recordSellerReply(
            widget.conversationId,
            text,
            idempotencyKey: _intent.forPayload(text),
          );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = inboxErrorText(l10n, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.recordMyReplyHelp,
          style: context.type.label.copyWith(
            color: context.palette.textSecondary,
          ),
        ),
        const SizedBox(height: Space.s12),
        if (_error != null) ...[
          FormErrorBanner(message: _error!),
          const SizedBox(height: Space.s12),
        ],
        AppTextField(
          label: l10n.fieldYourReply,
          controller: _text,
          maxLines: 6,
          error: _textError,
          enabled: !_saving,
          keyboardType: TextInputType.multiline,
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.saveReply,
          loading: _saving,
          expand: true,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

class _EditSuggestionForm extends StatefulWidget {
  const _EditSuggestionForm({required this.initial});

  final String initial;

  @override
  State<_EditSuggestionForm> createState() => _EditSuggestionFormState();
}

class _EditSuggestionFormState extends State<_EditSuggestionForm> {
  late final _text = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.editSuggestionHelp,
          style: context.type.label.copyWith(
            color: context.palette.textSecondary,
          ),
        ),
        const SizedBox(height: Space.s12),
        AppTextField(
          label: l10n.fieldReply,
          controller: _text,
          maxLines: 8,
          error: _error,
          keyboardType: TextInputType.multiline,
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.copyReply,
          icon: AppIcons.copy,
          expand: true,
          onPressed: () {
            final text = _text.text.trim();
            if (text.isEmpty || text.length > _maxMessage) {
              setState(
                () => _error = text.isEmpty
                    ? l10n.errMessageRequired
                    : l10n.errMessageTooLong,
              );
              return;
            }
            Navigator.of(context).pop(text);
          },
        ),
      ],
    );
  }
}
