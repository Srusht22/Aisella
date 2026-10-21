import 'package:flutter/foundation.dart';

/// The subscription plans (owner's proposal, prices in USD). Limits are
/// shown to the seller; they are not enforced yet, and nothing is charged
/// until a payment provider is approved and connected.
enum PlanTier {
  starter(priceUsd: 15, products: 50, ordersPerMonth: 100),
  pro(priceUsd: 25, products: 200, ordersPerMonth: 500),
  business(priceUsd: 49, products: 1000, ordersPerMonth: 2000);

  const PlanTier({
    required this.priceUsd,
    required this.products,
    required this.ordersPerMonth,
  });

  final int priceUsd;
  final int products;
  final int ordersPerMonth;
}

/// Every plan starts with this many free days.
const trialDays = 7;

@immutable
class PlanState {
  const PlanState({this.tier, this.trialStart});

  /// Null until the seller picks a plan.
  final PlanTier? tier;
  final DateTime? trialStart;

  bool get chosen => tier != null && trialStart != null;

  /// Whole days left in the trial on [now] (0 when it has ended).
  int daysLeft(DateTime now) {
    final start = trialStart;
    if (start == null) return 0;
    final end = start.add(const Duration(days: trialDays));
    final left = end.difference(now);
    if (left.isNegative) return 0;
    return (left.inHours / 24).ceil();
  }
}
