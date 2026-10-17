import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../../core/formatting/bidi.dart';
import '../../../core/formatting/digits.dart';
import '../../../core/formatting/money.dart';
import '../../../core/settings/app_settings.dart';
import '../../../design_system/components/status.dart';
import '../../../design_system/icons/app_icons.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../common/api_error_text.dart';
import '../../store/application/workspace_controller.dart';
import '../domain/order.dart';

/// Localised order wording shared by the order screens (Phase 1 §6.4 labels).

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

/// Icon and tone: never colour alone (Phase 2 CMP-StatusBadge). Drafts use
/// the pencil tone so a draft can never look approved (OR-02 #19a).
(IconData, Tone) statusLook(OrderStatus s) => switch (s) {
  OrderStatus.draft => (AppIcons.pencilSimple, Tone.pencil),
  OrderStatus.pendingApproval => (AppIcons.pencilSimple, Tone.pencil),
  OrderStatus.rejected => (AppIcons.prohibit, Tone.neutral),
  OrderStatus.approved => (AppIcons.sealCheck, Tone.info),
  OrderStatus.processing => (AppIcons.package, Tone.info),
  OrderStatus.dispatched => (AppIcons.truck, Tone.info),
  OrderStatus.delivered => (AppIcons.checkCircle, Tone.success),
  OrderStatus.deliveryFailed => (AppIcons.warning, Tone.warning),
  OrderStatus.returned => (AppIcons.arrowUUpLeft, Tone.neutral),
  OrderStatus.cancelled => (AppIcons.xCircle, Tone.neutral),
};

class OrderStatusBadge extends StatelessWidget {
  const OrderStatusBadge(this.status, {super.key});
  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, tone) = statusLook(status);
    return StatusBadge(
      label: statusLabel(AppLocalizations.of(context), status),
      icon: icon,
      tone: tone,
    );
  }
}

String filterLabel(AppLocalizations l10n, OrderFilter f) => switch (f) {
  OrderFilter.all => l10n.filterAll,
  OrderFilter.needsApproval => l10n.statusNeedsApproval,
  OrderFilter.drafts => l10n.filterDrafts,
  OrderFilter.active => l10n.filterActive,
  OrderFilter.delivered => l10n.statusDelivered,
  OrderFilter.problems => l10n.filterProblems,
  OrderFilter.closed => l10n.filterClosed,
};

/// "#1042", always LTR with Western digits (Phase 2 §07: order numbers).
String orderNumber(int n) => Bidi.ltr('#$n');

String reasonText(AppLocalizations l10n, String? reason) => switch (reason) {
  'customer_changed_mind' => l10n.rejectChangedMind,
  'not_serious' => l10n.rejectNotSerious,
  'duplicate' => l10n.reasonDuplicate,
  'out_of_stock' => l10n.reasonOutOfStock,
  'cannot_deliver' => l10n.reasonCannotDeliver,
  'customer_cancelled' => l10n.cancelCustomerCancelled,
  'unreachable' => l10n.failUnreachable,
  'refused' => l10n.failRefused,
  'wrong_address' => l10n.failWrongAddress,
  'other' => l10n.reasonOther,
  _ => '',
};

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

/// Short field names for the editor's "Still missing: …" line.
String missingText(AppLocalizations l10n, String field) => switch (field) {
  'customer_name' => l10n.fieldName,
  'customer_phone' => l10n.fieldPhone,
  'zone' => l10n.fieldZone,
  'area' => l10n.fieldArea,
  'delivery_fee' => l10n.fieldFee,
  'payment_method' => l10n.fieldPaymentMethod,
  _ => l10n.sectionItems,
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

String count(int value, DigitStyle digits) =>
    Bidi.ltr(Digits.display('$value', digits));

/// "Beige Abaya · M" with seller text isolated.
String itemName(String name, String label) => label.isEmpty
    ? Bidi.auto(name)
    : '${Bidi.auto(name)} · ${Bidi.auto(label)}';

/// API errors of the order functions (P-ERR-ACTION).
String orderErrorText(
  AppLocalizations l10n,
  ApiException e, {
  required DigitStyle digits,
}) => switch (e.code) {
  ApiErrorCode.invalidTransition => l10n.errOrderChangedStatus(
    statusLabel(l10n, OrderStatus.parse(e.currentStatus)),
  ),
  ApiErrorCode.incompleteOrder => l10n.errOrderIncomplete,
  ApiErrorCode.priceChanged => l10n.errPricesChanged,
  ApiErrorCode.lineUnavailable => l10n.errLinesUnavailable(
    e.detailList('lines').length,
  ),
  ApiErrorCode.insufficientStock => l10n.errLinesShort(
    e.detailList('lines').length,
  ),
  ApiErrorCode.emailNotVerified => l10n.errEmailNotVerifiedApprove,
  ApiErrorCode.forbidden => l10n.errOwnerOnly,
  ApiErrorCode.notFound => l10n.orderUnavailableTitle,
  ApiErrorCode.validationFailed when e.fields.containsKey('discount') =>
    l10n.errDiscountTooHigh,
  ApiErrorCode.validationFailed
      when e.fields.containsKey('cod_collected') ||
          e.fields.containsKey('amount') =>
    l10n.errCashTooHigh,
  ApiErrorCode.validationFailed when e.fields.values.contains('unavailable') =>
    l10n.errLinesUnavailable(
      e.fields.values.where((v) => v == 'unavailable').length,
    ),
  _ => apiErrorText(l10n, e),
};

/// Cause line of a failed load (P-ERR-LOAD).
String orderLoadErrorText(AppLocalizations l10n, Object error) =>
    switch (error) {
      ApiException(code: ApiErrorCode.network || ApiErrorCode.timeout) =>
        l10n.errNetwork,
      ApiException(code: ApiErrorCode.notFound) => l10n.orderUnavailableBody,
      _ => l10n.errorServer,
    };

/// The store's currency (one per store, BR-12).
Currency storeCurrency(WidgetRef ref) =>
    ref.watch(workspaceProvider.select((w) => w.value?.store?.currency)) ??
    Currency.iqd;
