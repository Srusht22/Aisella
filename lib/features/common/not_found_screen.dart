import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/l10n/l10n.dart';
import '../../design_system/components/app_button.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/icons/app_icons.dart';

/// Unknown routes and deep links (GL-04). Reveals nothing about records.
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      body: SafeArea(
        child: EmptyState(
          icon: AppIcons.question,
          title: l10n.notFoundTitle,
          body: l10n.notFoundBody,
          action: AppButton(
            label: l10n.goToToday,
            onPressed: () => context.go(Routes.today),
          ),
        ),
      ),
    );
  }
}
