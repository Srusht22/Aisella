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
import '../../../design_system/components/rows.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/form_widgets.dart';
import '../application/inbox_providers.dart';
import '../domain/conversation.dart';
import 'inbox_text.dart';

/// The AI assistant's settings: the store-wide switch (owner) and the written
/// policies it may quote. Without a written policy the assistant says the
/// owner will confirm (Phase 1 §8.2).
class AiSettingsScreen extends ConsumerWidget {
  const AiSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final settings = ref.watch(aiSettingsProvider);

    final Widget body = switch (settings) {
      AsyncData(:final value) => ListView(
        children: [
          ContentWidth(
            maxWidth: LayoutTokens.maxWidthForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.s12),
                RowGroup(
                  children: [
                    Material(
                      type: MaterialType.transparency,
                      child: SwitchListTile(
                        value: value.enabled,
                        title: Text(l10n.aiAssistantSwitch),
                        subtitle: Text(
                          l10n.aiAssistantSwitchHelp,
                          style: type.caption.copyWith(color: p.textSecondary),
                        ),
                        onChanged: (v) async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await ref
                                .read(inboxActionsProvider)
                                .setAiEnabled(v);
                          } on ApiException catch (e) {
                            showSnackOn(messenger, inboxErrorText(l10n, e));
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s12),
                Text(
                  l10n.aiNeverSends,
                  style: type.caption.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(
                  l10n.writtenPolicies,
                  action: AppButton(
                    label: l10n.addPolicy,
                    icon: AppIcons.plus,
                    variant: AppButtonVariant.tertiary,
                    onPressed: () => _showPolicySheet(context, null),
                  ),
                ),
                Text(
                  l10n.writtenPoliciesHelp,
                  style: type.caption.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: Space.s8),
                if (value.policies.isEmpty)
                  Text(
                    l10n.noPoliciesYet,
                    style: type.body.copyWith(color: p.textTertiary),
                  )
                else
                  RowGroup(
                    children: [
                      for (final policy in value.policies)
                        FieldRow(
                          label: policyTopicLabel(l10n, policy.topic),
                          value: Text(
                            Bidi.auto(policy.body),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(AppIcons.caretRight),
                          onTap: () => _showPolicySheet(context, policy),
                        ),
                    ],
                  ),
                const SizedBox(height: Space.s24),
              ],
            ),
          ),
        ],
      ),
      AsyncError(:final error) => ErrorState(
        cause: error is ApiException
            ? inboxErrorText(l10n, error)
            : l10n.errorServer,
        onRetry: () => ref.invalidate(aiSettingsProvider),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };

    return Scaffold(
      backgroundColor: p.bgCanvas,
      appBar: AppBar(title: Text(l10n.aiSettings)),
      body: body,
    );
  }
}

Future<void> _showPolicySheet(BuildContext context, StorePolicy? policy) =>
    showAppSheet<void>(
      context: context,
      title: policy == null ? context.l10n.addPolicy : context.l10n.editPolicy,
      builder: (_) => _PolicyForm(policy: policy),
    );

class _PolicyForm extends ConsumerStatefulWidget {
  const _PolicyForm({required this.policy});

  final StorePolicy? policy;

  @override
  ConsumerState<_PolicyForm> createState() => _PolicyFormState();
}

class _PolicyFormState extends ConsumerState<_PolicyForm> {
  late final _body = TextEditingController(text: widget.policy?.body ?? '');
  late PolicyTopic _topic = widget.policy?.topic ?? PolicyTopic.delivery;
  final _intent = IntentKey();
  bool _saving = false;
  String? _bodyError;
  String? _error;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final body = _body.text.trim();
    if (body.isEmpty || body.length > 1000) {
      setState(
        () => _bodyError = body.isEmpty
            ? l10n.errPolicyRequired
            : l10n.errPolicyTooLong,
      );
      return;
    }
    setState(() {
      _saving = true;
      _bodyError = null;
      _error = null;
    });
    try {
      await ref
          .read(inboxActionsProvider)
          .upsertPolicy(
            existing: widget.policy,
            topic: _topic,
            body: body,
            idempotencyKey: _intent.forPayload('${_topic.name}|$body'),
          );
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = inboxErrorText(l10n, e);
        });
      }
    }
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final ok = await showConfirmDialog(
      context: context,
      title: l10n.deletePolicyTitle,
      body: l10n.deletePolicyBody,
      confirmLabel: l10n.delete,
      cancelLabel: l10n.cancel,
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref.read(inboxActionsProvider).deletePolicy(widget.policy!);
      if (mounted) Navigator.of(context).pop();
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
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s8,
          children: [
            for (final t in PolicyTopic.values)
              ChoiceChip(
                label: Text(policyTopicLabel(l10n, t)),
                selected: _topic == t,
                showCheckmark: false,
                onSelected: _saving ? null : (_) => setState(() => _topic = t),
              ),
          ],
        ),
        const SizedBox(height: Space.s12),
        AppTextField(
          label: l10n.policyText,
          helper: l10n.policyTextHelp,
          controller: _body,
          maxLines: 6,
          error: _bodyError,
          enabled: !_saving,
          keyboardType: TextInputType.multiline,
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.save,
          loading: _saving,
          expand: true,
          onPressed: _saving ? null : _save,
        ),
        if (widget.policy != null) ...[
          const SizedBox(height: Space.s8),
          AppButton(
            label: l10n.deletePolicy,
            variant: AppButtonVariant.tertiary,
            onPressed: _saving ? null : _delete,
          ),
        ],
      ],
    );
  }
}
