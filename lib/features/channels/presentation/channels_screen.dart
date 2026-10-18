import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/components/inputs.dart';
import '../../../design_system/components/overlays.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/layout/responsive.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../common/channel_labels.dart';
import '../../common/form_widgets.dart';
import '../application/channel_providers.dart';
import '../domain/channel.dart';

/// Connected accounts (Phase 9): the store's messaging accounts in one of
/// five states, connecting a new one and disconnecting. Tokens and
/// authorization never pass through the app's storage.
class ChannelsScreen extends ConsumerWidget {
  const ChannelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final connections = ref.watch(connectionsProvider);
    final providers = ref.watch(channelProvidersProvider);

    Widget content() {
      if (connections case AsyncError(:final error)) {
        return ErrorState(
          cause: error is ApiException
              ? channelErrorText(l10n, error)
              : l10n.errorServer,
          onRetry: () => ref.read(channelActionsProvider).refreshAccounts(),
        );
      }
      final items = connections.value;
      final available = providers.value;
      if (items == null || available == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return ListView(
        children: [
          ContentWidth(
            maxWidth: LayoutTokens.maxWidthForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.s12),
                Text(
                  l10n.channelsIntro,
                  style: type.label.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.channelsYourAccounts),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.s8),
                    child: Text(
                      l10n.channelsNone,
                      style: type.body.copyWith(color: p.textTertiary),
                    ),
                  )
                else
                  for (final c in items) ...[
                    _ConnectionCard(connection: c),
                    const SizedBox(height: Space.s8),
                  ],
                const SizedBox(height: Space.s24),
                SectionHeader(l10n.channelsAdd),
                RowGroup(
                  children: [
                    for (final pr in available)
                      NavRow(
                        label: pr.name,
                        icon: AppIcons.chatsCircle,
                        trailing: Text(
                          pr.canConnect
                              ? connectionStateLabel(l10n, pr.uiState)
                              : l10n.channelNotAvailable,
                          style: type.caption.copyWith(color: p.textSecondary),
                        ),
                        onTap: pr.canConnect && pr.method != null
                            ? () => showConnectSheet(context, pr)
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: Space.s32),
              ],
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.channelsTitle),
        actions: [
          IconButton(
            tooltip: l10n.refresh,
            icon: const Icon(AppIcons.arrowClockwise),
            onPressed: () => ref.read(channelActionsProvider).refreshAccounts(),
          ),
        ],
      ),
      body: content(),
    );
  }
}

class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard({required this.connection});

  final ChannelConnection connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final c = connection;
    final (tone, icon) = connectionStateStyle(c.uiState);
    final body = connectionStateBody(l10n, c.uiState);
    final name = Bidi.auto(c.displayName ?? c.username ?? c.providerName);

    Future<void> disconnect() async {
      final messenger = ScaffoldMessenger.of(context);
      final ok = await showConfirmDialog(
        context: context,
        title: l10n.disconnectTitle(name),
        body: l10n.disconnectBody,
        confirmLabel: l10n.disconnect,
        cancelLabel: l10n.cancel,
        destructive: true,
      );
      if (!ok) return;
      try {
        await ref.read(channelActionsProvider).disconnect(c);
      } on ApiException catch (e) {
        showSnackOn(messenger, channelErrorText(l10n, e));
      }
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.bgSurface,
        border: Border.all(color: p.borderHairline, width: Strokes.hairline),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: type.bodyStrong.copyWith(color: p.textPrimary)),
            const SizedBox(height: Space.s2),
            Text(
              c.providerName,
              style: type.caption.copyWith(color: p.textSecondary),
            ),
            const SizedBox(height: Space.s8),
            Wrap(
              spacing: Space.s8,
              runSpacing: Space.s4,
              children: [
                StatusBadge(
                  label: connectionStateLabel(l10n, c.uiState),
                  icon: icon,
                  tone: tone,
                ),
                if (c.isTest)
                  StatusBadge(
                    label: l10n.connTestAccount,
                    icon: AppIcons.flask,
                    tone: Tone.warning,
                  ),
              ],
            ),
            if (body != null) ...[
              const SizedBox(height: Space.s8),
              Text(body, style: type.caption.copyWith(color: p.textSecondary)),
            ],
            const SizedBox(height: Space.s8),
            AppButton(
              label: l10n.disconnect,
              icon: AppIcons.signOut,
              variant: AppButtonVariant.tertiary,
              onPressed: disconnect,
            ),
          ],
        ),
      ),
    );
  }
}

/// Connects an account of [provider]: a token form for bots, or the
/// provider's authorization page in the browser.
Future<void> showConnectSheet(BuildContext context, ChannelProvider provider) =>
    showAppSheet<void>(
      context: context,
      title: context.l10n.connectTitle(provider.name),
      builder: (_) => provider.method == ConnectMethod.botToken
          ? _BotTokenForm(provider: provider)
          : _AuthorizeForm(provider: provider),
    );

class _BotTokenForm extends ConsumerStatefulWidget {
  const _BotTokenForm({required this.provider});

  final ChannelProvider provider;

  @override
  ConsumerState<_BotTokenForm> createState() => _BotTokenFormState();
}

class _BotTokenFormState extends ConsumerState<_BotTokenForm> {
  final _token = TextEditingController();
  bool _saving = false;
  bool _hidden = true;
  String? _tokenError;
  String? _error;

  @override
  void dispose() {
    // The token is not kept anywhere once the sheet closes.
    _token.clear();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final token = _token.text.trim();
    if (token.length < 20 || token.length > 500 || token.contains(' ')) {
      setState(() => _tokenError = l10n.botTokenInvalid);
      return;
    }
    setState(() {
      _saving = true;
      _tokenError = null;
      _error = null;
    });
    try {
      await ref
          .read(channelActionsProvider)
          .connectBot(widget.provider.id, token);
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnackOn(messenger, l10n.connectedSnack(widget.provider.name));
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = channelErrorText(l10n, e);
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
          l10n.botTokenHelp(widget.provider.name),
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
          label: l10n.botTokenLabel,
          controller: _token,
          ltr: true,
          obscureText: _hidden,
          error: _tokenError,
          enabled: !_saving,
          suffix: IconButton(
            tooltip: _hidden ? l10n.showPassword : l10n.hidePassword,
            icon: Icon(_hidden ? AppIcons.eye : AppIcons.eyeSlash),
            onPressed: () => setState(() => _hidden = !_hidden),
          ),
        ),
        const SizedBox(height: Space.s16),
        AppButton(
          label: l10n.connectAction,
          loading: _saving,
          expand: true,
          onPressed: _saving ? null : _connect,
        ),
      ],
    );
  }
}

class _AuthorizeForm extends ConsumerStatefulWidget {
  const _AuthorizeForm({required this.provider});

  final ChannelProvider provider;

  @override
  ConsumerState<_AuthorizeForm> createState() => _AuthorizeFormState();
}

class _AuthorizeFormState extends ConsumerState<_AuthorizeForm> {
  bool _busy = false;
  bool _opened = false;
  String? _error;

  Future<void> _open() async {
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final opened = await ref
          .read(channelActionsProvider)
          .startAuthorization(widget.provider.id);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _opened = opened;
        _error = opened ? null : l10n.authorizeOpenFailed;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = channelErrorText(l10n, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = widget.provider.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.provider.method == ConnectMethod.whatsappSignup
              ? l10n.authorizeWhatsappBody
              : l10n.authorizeBody(name),
          style: context.type.label.copyWith(
            color: context.palette.textSecondary,
          ),
        ),
        const SizedBox(height: Space.s12),
        if (_error != null) ...[
          FormErrorBanner(message: _error!),
          const SizedBox(height: Space.s12),
        ],
        if (_opened) ...[
          AppBanner(
            tone: Tone.info,
            icon: AppIcons.clockCounterClockwise,
            title: l10n.connStateAwaiting,
            body: l10n.authorizeReturn,
          ),
          const SizedBox(height: Space.s12),
        ],
        AppButton(
          label: l10n.authorizeOpen(name),
          loading: _busy,
          expand: true,
          onPressed: _busy ? null : _open,
        ),
        if (_opened) ...[
          const SizedBox(height: Space.s8),
          AppButton(
            label: l10n.done,
            variant: AppButtonVariant.secondary,
            expand: true,
            onPressed: () {
              ref.read(channelActionsProvider).refreshAccounts();
              Navigator.of(context).pop();
            },
          ),
        ],
      ],
    );
  }
}
