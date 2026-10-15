import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/config/app_config.dart';
import '../../core/l10n/l10n.dart';
import '../../design_system/components/rows.dart';
import '../../design_system/icons/app_icons.dart';
import '../../design_system/layout/responsive.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';
import '../common/deferred_feature_screen.dart';

/// ST-01 Store menu. Rows for later phases are marked and open an honest
/// "not available yet" screen. Sign out appears once accounts exist (Phase 5).
class StoreMenuScreen extends ConsumerWidget {
  const StoreMenuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final config = ref.watch(appConfigProvider);

    Widget later(DeferredFeature f, IconData icon) => NavRow(
      label: f.label(l10n),
      icon: icon,
      trailing: Text(
        l10n.laterRelease,
        style: type.caption.copyWith(color: p.textTertiary),
      ),
      onTap: () => context.push(Routes.later(f)),
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
                      label: config.sampleData
                          ? l10n.sampleStoreName
                          : l10n.noStoreConnected,
                      icon: AppIcons.storefront,
                      iconColor: p.textBrand,
                    ),
                  ],
                ),
                const SizedBox(height: Space.s24),
                RowGroup(
                  children: [
                    later(DeferredFeature.customers, AppIcons.users),
                    later(DeferredFeature.storeProfile, AppIcons.storefront),
                    later(DeferredFeature.deliveryZones, AppIcons.truck),
                    later(DeferredFeature.payments, AppIcons.money),
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
                    later(DeferredFeature.account, AppIcons.userCircle),
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
                const SizedBox(height: Space.s32),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
