import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/formatting/money.dart';

/// Counts for the Today screen (Phase 1 Journey G). Phase 7 replaces the
/// sample source with the `v_today_attention` read (Phase 3 contracts §3.8).
/// Low stock is not here: it is real since Phase 6 (catalog summary).
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

/// Phase 4 default when sample data is off: no backend exists yet.
class NotConnectedTodayRepository implements TodayRepository {
  const NotConnectedTodayRepository();

  @override
  Future<TodayResult> load() async => const TodayNoStore();
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

final todayRepositoryProvider = Provider<TodayRepository>(
  (ref) => ref.watch(appConfigProvider).sampleData
      ? const SampleTodayRepository()
      : const NotConnectedTodayRepository(),
);

final todayProvider = FutureProvider<TodayResult>(
  (ref) => ref.watch(todayRepositoryProvider).load(),
);
