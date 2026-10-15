import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/l10n/l10n.dart';
import '../design_system/icons/app_icons.dart';
import '../design_system/layout/responsive.dart';
import '../design_system/theme/theme_ext.dart';
import '../design_system/tokens/tokens.g.dart';

/// Responsive app shell (Phase 2 IA §1): bottom bar on phones, navigation
/// rail from 600 dp. Each tab keeps its own stack; re-selecting the active
/// tab returns to its root. Back at a non-Today tab root goes to Today;
/// back at Today leaves the app (Phase 2 IA §3.1).
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _select(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = context.palette;
    final type = context.type;
    final destinations = [
      (l10n.navToday, AppIcons.house, AppIcons.houseFill),
      (l10n.navInbox, AppIcons.chatsCircle, AppIcons.chatsCircleFill),
      (l10n.navOrders, AppIcons.receipt, AppIcons.receiptFill),
      (l10n.navProducts, AppIcons.package, AppIcons.packageFill),
    ];
    final index = navigationShell.currentIndex;
    final rail = WindowClass.of(context).usesRail;

    final body = PopScope<Object?>(
      canPop: index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(0);
      },
      child: navigationShell,
    );

    if (rail) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: _select,
              labelType: NavigationRailLabelType.all,
              backgroundColor: p.bgSurface,
              indicatorColor: p.bgBrandWeak,
              minWidth: 72,
              selectedLabelTextStyle: type.label.copyWith(
                color: p.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelTextStyle: type.label.copyWith(
                color: p.textSecondary,
              ),
              destinations: [
                for (final (label, icon, filled) in destinations)
                  NavigationRailDestination(
                    icon: Icon(
                      icon,
                      color: p.textSecondary,
                      size: Sizes.iconLg,
                    ),
                    selectedIcon: Icon(
                      filled,
                      color: p.brandPrimary,
                      size: Sizes.iconLg,
                    ),
                    label: Text(label),
                  ),
              ],
            ),
            VerticalDivider(width: Strokes.hairline, color: p.borderHairline),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: p.borderHairline, width: Strokes.hairline),
          ),
        ),
        child: NavigationBarTheme(
          data: NavigationBarThemeData(
            labelTextStyle: WidgetStateProperty.resolveWith(
              (states) => type.label.copyWith(
                color: states.contains(WidgetState.selected)
                    ? p.textPrimary
                    : p.textSecondary,
                fontWeight: states.contains(WidgetState.selected)
                    ? FontWeight.w600
                    : null,
              ),
            ),
          ),
          child: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: _select,
            height: LayoutTokens.bottomNavHeight,
            backgroundColor: p.bgSurface,
            surfaceTintColor: Colors.transparent,
            indicatorColor: p.bgBrandWeak,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              for (final (label, icon, filled) in destinations)
                NavigationDestination(
                  icon: Icon(icon, color: p.textSecondary, size: Sizes.iconLg),
                  selectedIcon: Icon(
                    filled,
                    color: p.brandPrimary,
                    size: Sizes.iconLg,
                  ),
                  label: label,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
