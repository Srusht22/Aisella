import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/config/app_config.dart';
import '../../../core/l10n/l10n.dart';
import '../../../design_system/components/app_button.dart';
import '../../../design_system/components/feedback.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../common/top_level_page.dart';

/// Orders tab root. Order management arrives in Phase 7; this states it
/// plainly. Sample-data builds also offer the OR-02 design preview.
class OrdersHomeScreen extends ConsumerWidget {
  const OrdersHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sample = ref.watch(appConfigProvider).sampleData;
    return TopLevelPage(
      title: l10n.ordersTitle,
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: AppIcons.receipt,
            title: l10n.deferredTitle(l10n.ordersTitle),
            body: l10n.deferredOrdersBody,
            action: sample
                ? AppButton(
                    label: l10n.previewDraftReview,
                    icon: AppIcons.flask,
                    variant: AppButtonVariant.secondary,
                    onPressed: () => context.push(Routes.draftPreview),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}
