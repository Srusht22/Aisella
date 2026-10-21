import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/formatting/bidi.dart';
import '../../core/formatting/phone.dart';
import '../../core/l10n/l10n.dart';
import '../../design_system/components/app_button.dart';
import '../../design_system/components/rows.dart';
import '../../design_system/icons/app_icons.dart';
import '../../design_system/layout/responsive.dart';
import '../../design_system/motion/motion.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../channels/application/channel_providers.dart';
import '../channels/domain/channel.dart';
import '../fulfilment/application/fulfilment_providers.dart';
import '../fulfilment/domain/fulfilment.dart';

/// One place for everything the store is connected to: the social and
/// messaging accounts customers write to, and the drivers who deliver.
/// Managing each lives on its own screen; this one shows the state at a
/// glance.
class ConnectionsScreen extends ConsumerWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final providers = ref.watch(channelProvidersProvider);
    final connections = ref.watch(connectionsProvider);
    final couriers = ref.watch(couriersProvider(false));

    var i = 0;
    Widget stagger(Widget child) => _Stagger(index: i++, child: child);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.connectionsTitle)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.s32),
        children: [
          ContentWidth(
            maxWidth: LayoutTokens.maxWidthForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.s8),
                stagger(
                  Text(
                    l10n.connectionsBody,
                    style: type.bodyLarge.copyWith(color: p.textSecondary),
                  ),
                ),
                const SizedBox(height: Space.s24),
                stagger(SectionHeader(l10n.connectionsSocial)),
                switch ((providers, connections)) {
                  (AsyncData(value: final ps), AsyncData(value: final cs)) =>
                    stagger(
                      RowGroup(
                        children: [
                          for (final provider in ps)
                            _SocialRow(
                              provider: provider,
                              connection: cs
                                  .where((c) => c.provider == provider.id)
                                  .firstOrNull,
                            ),
                        ],
                      ),
                    ),
                  (AsyncError(), _) || (_, AsyncError()) => Text(
                    l10n.connectionsUnavailable,
                    style: type.body.copyWith(color: p.textSecondary),
                  ),
                  _ => const _Loading(),
                },
                const SizedBox(height: Space.s8),
                stagger(
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AppButton(
                      label: l10n.connectionsManageSocial,
                      icon: AppIcons.chatsCircle,
                      variant: AppButtonVariant.secondary,
                      onPressed: () => context.push(Routes.storeChannels),
                    ),
                  ),
                ),
                const SizedBox(height: Space.s32),
                stagger(SectionHeader(l10n.connectionsDrivers)),
                switch (couriers) {
                  AsyncData(value: final list) when list.isEmpty => stagger(
                    Text(
                      l10n.connectionsNoDrivers,
                      style: type.body.copyWith(color: p.textSecondary),
                    ),
                  ),
                  AsyncData(value: final list) => stagger(
                    RowGroup(
                      children: [for (final c in list) _DriverRow(courier: c)],
                    ),
                  ),
                  AsyncError() => Text(
                    l10n.connectionsUnavailable,
                    style: type.body.copyWith(color: p.textSecondary),
                  ),
                  _ => const _Loading(),
                },
                const SizedBox(height: Space.s8),
                stagger(
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AppButton(
                      label: l10n.connectionsManageDrivers,
                      icon: AppIcons.truck,
                      variant: AppButtonVariant.secondary,
                      onPressed: () => context.push(Routes.storeCouriers),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SocialRow extends StatelessWidget {
  const _SocialRow({required this.provider, required this.connection});

  final ChannelProvider provider;
  final ChannelConnection? connection;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final c = connection;
    final connected = c != null && c.uiState == ConnectionUiState.connected;
    final account = c == null ? null : (c.displayName ?? c.username);
    return NavRow(
      label: provider.name,
      icon: AppIcons.chatsCircle,
      iconColor: connected ? p.successFg : p.textTertiary,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: Motion.fade(context, MotionTokens.md),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? p.successFg : p.borderControl,
            ),
          ),
          const SizedBox(width: Space.s8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              connected
                  ? (account == null
                        ? l10n.connectionsConnected
                        : l10n.connectionsConnectedAs(Bidi.auto(account)))
                  : l10n.connectionsNotConnected,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.caption.copyWith(
                color: connected ? p.successFg : p.textSecondary,
              ),
            ),
          ),
        ],
      ),
      onTap: () => context.push(Routes.storeChannels),
    );
  }
}

class _DriverRow extends StatelessWidget {
  const _DriverRow({required this.courier});

  final Courier courier;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final type = context.type;
    return NavRow(
      label: Bidi.auto(courier.name),
      icon: AppIcons.truck,
      iconColor: p.textBrand,
      trailing: courier.phone == null
          ? null
          : Text(
              PhoneNumbers.display(courier.phone!),
              style: type.caption.copyWith(color: p.textSecondary),
            ),
      onTap: () => context.push(Routes.storeCouriers),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 80,
    child: Center(child: CircularProgressIndicator()),
  );
}

/// Sections fade and rise in one after another.
class _Stagger extends StatelessWidget {
  const _Stagger({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return child;
    final delay = 50 * index;
    final total = 300 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: MotionTokens.enter),
      child: child,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - v)),
          child: child,
        ),
      ),
    );
  }
}
