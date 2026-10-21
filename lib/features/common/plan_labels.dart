import '../../core/l10n/l10n.dart';
import '../billing/domain/plan.dart';

String planName(AppLocalizations l10n, PlanTier t) => switch (t) {
  PlanTier.starter => l10n.planStarter,
  PlanTier.pro => l10n.planPro,
  PlanTier.business => l10n.planBusiness,
};

String planTagline(AppLocalizations l10n, PlanTier t) => switch (t) {
  PlanTier.starter => l10n.planStarterTag,
  PlanTier.pro => l10n.planProTag,
  PlanTier.business => l10n.planBusinessTag,
};

/// "Pro · free trial, 5 days left", or a prompt when no plan is chosen.
String planStatusText(AppLocalizations l10n, PlanState s, DateTime now) {
  final tier = s.tier;
  if (tier == null) return l10n.planNone;
  final left = s.daysLeft(now);
  return left > 0
      ? l10n.planTrialLeft(planName(l10n, tier), '$left')
      : l10n.planTrialEnded(planName(l10n, tier));
}
