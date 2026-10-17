import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/config/app_config.dart';
import '../../core/l10n/l10n.dart';
import '../../design_system/components/overlays.dart';
import '../../design_system/components/rows.dart';
import '../../design_system/icons/app_icons.dart';
import '../../design_system/layout/responsive.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../auth/application/auth_controller.dart';
import '../common/deferred_feature_screen.dart';
import '../common/store_forms.dart';
import '../store/application/workspace_controller.dart';

/// ST-01 Store menu. Rows for later phases are marked and open an honest
/// "not available yet" screen.
class StoreMenuScreen extends ConsumerWidget {
  const StoreMenuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final config = ref.watch(appConfigProvider);
    final store = ref.watch(workspaceProvider).value?.store;

    Future<void> signOut() async {
      final confirmed = await showConfirmDialog(
        context: context,
        title: l10n.signOutConfirmTitle,
        body: l10n.signOutConfirmBody,
        confirmLabel: l10n.menuSignOut,
        cancelLabel: l10n.cancel,
      );
      if (confirmed) {
        await ref.read(authControllerProvider.notifier).signOut();
      }
    }

    Widget later(DeferredFeature f, IconData icon) => NavRow(
      label: f.label(l10n),
      icon: icon,
      trailing: Text(
        l10n.laterRelease,
        style: type.caption.copyWith(color: p.textTertiary),
      ),
      onTap: () => context.push(Routes.later(f.name)),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.storeMenuTitle)),
      body: ListView(
        children: [
          ContentWidth(
            maxWidth: LayoutTokens.maxWidthForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: Space.s8),
                RowGroup(
                  children: [
                    NavRow(
                      label: store?.name ?? '',
                      icon: AppIcons.storefront,
                      iconColor: p.textBrand,
                      trailing: store == null
                          ? null
                          : Text(
                              cityLabel(l10n, store.businessCity),
                              style: type.caption.copyWith(
                                color: p.textSecondary,
                              ),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s24),
                RowGroup(
                  children: [
                    later(DeferredFeature.customers, AppIcons.users),
                    NavRow(
                      label: l10n.menuStoreProfile,
                      icon: AppIcons.storefront,
                      onTap: () => context.push(Routes.storeProfile),
                    ),
                    NavRow(
                      label: l10n.menuDeliveryZones,
                      icon: AppIcons.truck,
                      onTap: () => context.push(Routes.storeZones),
                    ),
                    NavRow(
                      label: l10n.menuPayments,
                      icon: AppIcons.money,
                      onTap: () => context.push(Routes.storePayments),
                    ),
                    NavRow(
                      label: l10n.sectionInventory,
                      icon: AppIcons.package,
                      onTap: () => context.push(Routes.storeInventory),
                    ),
                    later(DeferredFeature.policies, AppIcons.scales),
                    later(DeferredFeature.channels, AppIcons.chatsCircle),
                  ],
                ),
                const SizedBox(height: Space.s24),
                RowGroup(
                  children: [
                    NavRow(
                      label: l10n.menuLanguageDisplay,
                      icon: AppIcons.translate,
                      onTap: () => context.push(Routes.storeLanguage),
                    ),
                    NavRow(
                      label: l10n.menuAccount,
                      icon: AppIcons.userCircle,
                      onTap: () => context.push(Routes.storeAccount),
                    ),
                    NavRow(
                      label: l10n.termsAndPrivacy,
                      icon: AppIcons.scales,
                      onTap: () => context.push(Routes.storeLegal),
                    ),
                    NavRow(
                      label: l10n.menuLegal,
                      icon: AppIcons.bookOpen,
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: 'Aisellia',
                      ),
                    ),
                    if (!config.isProduction)
                      NavRow(
                        label: l10n.menuDesignSystem,
                        icon: AppIcons.flask,
                        onTap: () => context.push(Routes.storeGallery),
                      ),
                  ],
                ),
                const SizedBox(height: Space.s24),
                RowGroup(
                  children: [
                    NavRow(
                      label: l10n.menuSignOut,
                      icon: AppIcons.signOut,
                      iconColor: p.dangerFg,
                      labelColor: p.dangerFg,
                      onTap: signOut,
                    ),
                  ],
                ),
                const SizedBox(height: Space.s32),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
