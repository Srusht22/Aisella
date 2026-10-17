import 'package:flutter/widgets.dart';

import '../../core/formatting/bidi.dart';
import '../../core/formatting/money.dart';
import '../../core/settings/app_settings.dart';
import '../../l10n/gen/app_localizations.dart';
import '../orders/domain/order.dart';

/// Order wording shared by the order screens and the screens that link to an
/// order (the inbox's AI draft card). Re-exported by orders' order_text.dart.

String statusLabel(AppLocalizations l10n, OrderStatus s) => switch (s) {
  OrderStatus.draft => l10n.statusDraft,
  OrderStatus.pendingApproval => l10n.statusNeedsApproval,
  OrderStatus.rejected => l10n.statusRejected,
  OrderStatus.approved => l10n.statusApproved,
  OrderStatus.processing => l10n.statusPreparing,
  OrderStatus.dispatched => l10n.statusOutForDelivery,
  OrderStatus.delivered => l10n.statusDelivered,
  OrderStatus.deliveryFailed => l10n.statusDeliveryFailed,
  OrderStatus.returned => l10n.statusReturned,
  OrderStatus.cancelled => l10n.statusCancelled,
};

/// "#1042", always LTR with Western digits (Phase 2 §07: order numbers).
String orderNumber(int n) => Bidi.ltr('#$n');

/// The missing-field issues (BR-36) as the review screen lists them.
String issueText(AppLocalizations l10n, OrderIssue i) => switch (i.field) {
  'customer_name' => l10n.issueCustomerName,
  'customer_phone' => l10n.issueCustomerPhone,
  'zone' => l10n.issueZone,
  'area' => l10n.issueArea,
  'delivery_fee' => l10n.issueDeliveryFee,
  'payment_method' => l10n.issuePaymentMethod,
  'lines' when i.kind == 'missing' => l10n.issueNoItems,
  'lines' when i.kind == 'quantity_inferred' => l10n.issueQuantityToConfirm,
  _ => l10n.issueItemToResolve,
};

String money(
  BuildContext context,
  int amount,
  Currency currency,
  DigitStyle digits,
) => Money.format(
  amount,
  currency,
  locale: Localizations.localeOf(context),
  digits: digits,
);
