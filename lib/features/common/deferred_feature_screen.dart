import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../design_system/components/feedback.dart';
import '../../design_system/icons/app_icons.dart';

/// Destinations planned for later phases (Phase 4 §11): reachable, honest,
/// and never pretending to work.
enum DeferredFeature {
  customers,
  policies,
  channels,
  productDetails;

  String label(AppLocalizations l10n) => switch (this) {
    DeferredFeature.customers => l10n.menuCustomers,
    DeferredFeature.policies => l10n.menuPolicies,
    DeferredFeature.channels => l10n.menuChannels,
    DeferredFeature.productDetails => l10n.productDetails,
  };
}

class DeferredFeatureScreen extends StatelessWidget {
  const DeferredFeatureScreen({super.key, required this.feature});

  final DeferredFeature feature;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = feature.label(l10n);
    return Scaffold(
      appBar: AppBar(title: Text(label)),
      body: SafeArea(
        child: EmptyState(
          icon: AppIcons.wrench,
          title: l10n.deferredTitle(label),
          body: l10n.deferredBody,
        ),
      ),
    );
  }
}
