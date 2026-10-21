/// Product switches decided by the owner.
abstract final class Features {
  /// Delivery tracking after "Preparing" (out for delivery, delivered,
  /// delivery problems, delivery lists, courier cash). Off by the owner's
  /// decision (2026-10-21): orders stop at Preparing in the app. The
  /// database keeps every state, so turning this back on restores the
  /// screens without a migration.
  static const deliveryTracking = false;
}
