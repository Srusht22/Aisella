import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/config/app_config.dart';
import '../../core/l10n/l10n.dart';
import '../../design_system/components/media.dart';
import '../../design_system/layout/responsive.dart';
import '../../design_system/theme/theme_ext.dart';
import '../../design_system/tokens/tokens.g.dart';

/// Scaffold for the four tab roots: large title that collapses on scroll,
/// store button at the end (Phase 2 IA §1, CMP AppBar.large).
class TopLevelPage extends ConsumerWidget {
  const TopLevelPage({
    super.key,
    required this.title,
    required this.slivers,
    this.subtitle,
    this.floatingActionButton,
  });

  final String title;
  final String? subtitle;
  final List<Widget> slivers;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final type = context.type;
    final sample = ref.watch(appConfigProvider).sampleData;
    final storeName = context.l10n.sampleStoreName;
    return Scaffold(
      backgroundColor: p.bgCanvas,
      floatingActionButton: floatingActionButton,
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            backgroundColor: p.bgCanvas,
            surfaceTintColor: Colors.transparent,
            automaticallyImplyLeading: false,
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              StoreButton(
                initials: sample ? storeName.characters.first : null,
                tooltip: context.l10n.storeMenuTooltip,
                onPressed: () => context.push(Routes.store),
              ),
              const SizedBox(width: Space.s8),
            ],
          ),
          if (subtitle != null)
            SliverToBoxAdapter(
              child: ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Space.s16),
                  child: Text(
                    subtitle!,
                    style: type.label.copyWith(color: p.textSecondary),
                  ),
                ),
              ),
            ),
          ...slivers,
          const SliverToBoxAdapter(child: SizedBox(height: Space.s32)),
        ],
      ),
    );
  }
}
