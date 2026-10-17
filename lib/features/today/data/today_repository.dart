import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/formatting/money.dart';
import '../../orders/application/order_providers.dart';
import '../../orders/domain/order.dart';
import '../../store/application/workspace_controller.dart'
    show noAutomaticRetry;

/// Counts for the Today screen (Phase 1 Journey G). Since Phase 7 they come
/// from the order summary (`api.order_summary`); conversations ("needs you")
/// arrive with Phase 8. Low stock comes from the catalog summary.
@immutable
class TodaySnapshot {
  const TodaySnapshot({
    required this.currency,
    required this.needsApproval,
    required this.needsYou,
    required this.draftsMissing,
    required this.toDispatch,
    required this.deliveryProblems,
    required this.cashToCollect,
    required this.approvedToday,
    required this.deliveredToday,
    required this.valueApprovedToday,
  });

  final Currency currency;
  final int needsApproval;
  final int needsYou;
  final int draftsMissing;
  final int toDispatch;
  final int deliveryProblems;
  final int cashToCollect;
  final int approvedToday;
  final int deliveredToday;
  final int valueApprovedToday;

  bool get allCaughtUp =>
      needsApproval +
          needsYou +
          draftsMissing +
          toDispatch +
          deliveryProblems +
          cashToCollect ==
      0;
}

/// Result of loading Today: either a snapshot (with its provenance) or the
/// honest "no store connected yet" state.
sealed class TodayResult {
  const TodayResult();
}

class TodayNoStore extends TodayResult {
  const TodayNoStore();
}

class TodayData extends TodayResult {
  const TodayData(this.snapshot, {required this.isSample});

  final TodaySnapshot snapshot;

  /// True when the data is fictional sample data for design review.
  final bool isSample;
}

abstract interface class TodayRepository {
  Future<TodayResult> load();
}

/// SAMPLE DATA — fictional values for design review only. Never shown
/// without the sample banner, never used in production builds.
class SampleTodayRepository implements TodayRepository {
  const SampleTodayRepository({
    this.latency = const Duration(milliseconds: 450),
  });

  final Duration latency;

  @override
  Future<TodayResult> load() async {
    await Future<void>.delayed(latency);
    return const TodayData(
      TodaySnapshot(
        currency: Currency.iqd,
        needsApproval: 3,
        needsYou: 1,
        draftsMissing: 2,
        toDispatch: 4,
        deliveryProblems: 1,
        cashToCollect: 420000,
        approvedToday: 6,
        deliveredToday: 4,
        valueApprovedToday: 455000,
      ),
      isSample: true,
    );
  }
}

/// Sample builds may override this with [SampleTodayRepository]; otherwise
/// Today reads the real order counts.
final todayRepositoryProvider = Provider<TodayRepository?>(
  (ref) => ref.watch(appConfigProvider).sampleData
      ? const SampleTodayRepository()
      : null,
);

/// Today from the store's orders: no store means nothing to show yet.
TodayResult todayFromCounts(OrderCounts? c) => c == null
    ? const TodayNoStore()
    : TodayData(
        TodaySnapshot(
          currency: c.currency,
          needsApproval: c[OrderFilter.needsApproval],
          needsYou: 0,
          draftsMissing: c[OrderFilter.drafts],
          toDispatch: c.toDispatch,
          deliveryProblems: c.deliveryFailed,
          cashToCollect: c.codOutstanding,
          approvedToday: c.approvedToday,
          deliveredToday: c.deliveredToday,
          valueApprovedToday: c.valueApprovedToday,
        ),
        isSample: false,
      );

final todayProvider = FutureProvider<TodayResult>(retry: noAutomaticRetry, (
  ref,
) async {
  final sample = ref.watch(todayRepositoryProvider);
  if (sample != null) return sample.load();
  return todayFromCounts(await ref.watch(orderCountsProvider.future));
});
