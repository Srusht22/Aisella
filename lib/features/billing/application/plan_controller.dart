import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/settings/key_value_store.dart';
import '../domain/plan.dart';

/// The chosen plan and trial start, kept on this device. The server takes
/// this over when billing is connected (owner approval needed for a
/// payment provider).
class PlanController extends Notifier<PlanState> {
  static const _kTier = 'plan.tier';
  static const _kTrialStart = 'plan.trialStart';

  @override
  PlanState build() {
    final store = ref.watch(keyValueStoreProvider);
    final tier = PlanTier.values
        .where((t) => t.name == store.read(_kTier))
        .firstOrNull;
    final start = DateTime.tryParse(store.read(_kTrialStart) ?? '');
    return PlanState(tier: tier, trialStart: tier == null ? null : start);
  }

  /// Picks a plan. The trial starts the first time; changing plan later
  /// keeps the original start, so the trial cannot be restarted.
  Future<void> choose(PlanTier tier) async {
    final store = ref.read(keyValueStoreProvider);
    final start = state.trialStart ?? ref.read(clockProvider)();
    state = PlanState(tier: tier, trialStart: start);
    await store.write(_kTier, tier.name);
    await store.write(_kTrialStart, start.toUtc().toIso8601String());
  }
}

final planProvider = NotifierProvider<PlanController, PlanState>(
  PlanController.new,
);
