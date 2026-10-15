import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/icons/app_icons.dart';
import '../common/top_level_page.dart';

/// Inbox tab root. Conversations arrive in Phase 8; until then the screen
/// says so plainly and never implies a messaging channel is connected.
class InboxScreen extends StatelessWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TopLevelPage(
      title: l10n.navInbox,
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: AppIcons.chatsCircle,
            title: l10n.deferredTitle(l10n.navInbox),
            body: l10n.deferredInboxBody,
          ),
        ),
      ],
    );
  }
}
