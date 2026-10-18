import '../../core/backend/api.dart';
import '../../core/l10n/l10n.dart';
import '../fulfilment/domain/fulfilment.dart';
import 'api_error_text.dart';

/// How a recorded payment was made (record only).
String paymentChannelLabel(AppLocalizations l10n, PaymentChannel c) =>
    switch (c) {
      PaymentChannel.fib => l10n.channelFib,
      PaymentChannel.fastpay => l10n.channelFastpay,
      PaymentChannel.zaincash => l10n.channelZaincash,
      PaymentChannel.asiahawala => l10n.channelAsiahawala,
      PaymentChannel.bankTransfer => l10n.channelBankTransfer,
      PaymentChannel.other => l10n.channelOther,
    };

String deliveryListStatusLabel(AppLocalizations l10n, DeliveryListStatus s) =>
    switch (s) {
      DeliveryListStatus.open => l10n.listOpen,
      DeliveryListStatus.handedOver => l10n.listHandedOver,
      DeliveryListStatus.cancelled => l10n.statusCancelled,
    };

/// Errors of courier, delivery-list, payment and settlement actions.
String fulfilmentErrorText(AppLocalizations l10n, ApiException e) {
  final field = e.fields.entries.firstOrNull;
  return switch ((e.code, field?.key, field?.value)) {
    (ApiErrorCode.validationFailed, 'name', 'duplicate') =>
      l10n.errCourierNameDuplicate,
    (ApiErrorCode.validationFailed, 'name', _) => l10n.errCourierNameRequired,
    (ApiErrorCode.validationFailed, 'phone', _) => l10n.errPhoneInvalid(
      '0750 123 4567',
    ),
    (ApiErrorCode.validationFailed, 'courier_id', 'required') =>
      l10n.errChooseCourier,
    (ApiErrorCode.validationFailed, 'courier_id', _) => l10n.errCourierInvalid,
    (ApiErrorCode.validationFailed, 'order_ids', 'on_another_list') =>
      l10n.errOnAnotherList,
    (ApiErrorCode.validationFailed, 'amount', 'exceeds_due') =>
      l10n.errAmountExceeds,
    (ApiErrorCode.validationFailed, 'amount', _) => l10n.errAmountInvalid,
    (ApiErrorCode.incompleteOrder, _, _) => l10n.errListBlocked(
      e.detailList('orders').map((o) => '#${o['order_number']}').join(', '),
    ),
    (ApiErrorCode.invalidTransition, _, _) => l10n.errOrderNotReady,
    (ApiErrorCode.forbidden, _, _) => l10n.errOwnerOnly,
    _ => apiErrorText(l10n, e),
  };
}
