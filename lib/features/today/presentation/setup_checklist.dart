import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/route_guard.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/rows.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../design_system/theme/theme_ext.dart';
import '../../../design_system/tokens/tokens.g.dart';
import '../../store/application/workspace_controller.dart';

/// TD-01 setup checklist (Phase 1 US-008, Journey A step 8). Completion comes
/// from the server: the store exists, and active delivery zones. Steps that
/// belong to later phases are listed honestly as "In a later release".
class SetupChecklist extends ConsumerWidget {
  const SetupChecklist({super.key});

  static const total = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final digits = ref.watch(settingsProvider).digits;
    final store = ref.watch(workspaceProvider).value?.store;
    if (store == null) return const SizedBox.shrink();
    final zones = ref.watch(zonesProvider);
    final hasZones = zones.value?.isNotEmpty ?? false;
    final done = 1 + (hasZones ? 1 : 0);

    Widget item({
      required String label,
      required bool complete,
      bool later = false,
      VoidCallback? onTap,
    }) => NavRow(
      label: label,
      icon: complete ? AppIcons.checkCircleFill : AppIcons.circle,
      iconColor: complete ? p.successFg : p.textTertiary,
      labelColor: later ? p.textTertiary : null,
      semanticsLabel:
          '$label, ${complete
              ? l10n.checklistDone
              : later
              ? l10n.checklistLater
              : l10n.checklistToDo}',
      trailing: later
          ? Text(
              l10n.checklistLater,
              style: type.caption.copyWith(color: p.textTertiary),
            )
          : null,
      onTap: complete || later ? null : onTap,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            l10n.checklistTitle,
            action: Text(
              Digits.display(l10n.checklistProgress(done, total), digits),
              style: type.caption.copyWith(color: p.textSecondary),
            ),
          ),
          RowGroup(
            children: [
              item(label: l10n.checklistStore, complete: true),
              item(
                label: l10n.checklistDelivery,
                complete: hasZones,
                onTap: () => context.push(Routes.storeZones),
              ),
              item(label: l10n.checklistProduct, complete: false, later: true),
              item(label: l10n.checklistSandbox, complete: false, later: true),
              item(label: l10n.checklistImport, complete: false, later: true),
            ],
          ),
        ],
      ),
    );
  }
}
