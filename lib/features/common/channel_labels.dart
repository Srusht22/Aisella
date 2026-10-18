import 'package:flutter/widgets.dart' show IconData;

import '../../core/backend/api.dart';
import '../../core/l10n/l10n.dart';
import '../../design_system/components/status.dart';
import '../../design_system/icons/app_icons.dart';
import '../channels/domain/channel.dart';
import 'api_error_text.dart';

String connectionStateLabel(AppLocalizations l10n, ConnectionUiState s) =>
    switch (s) {
      ConnectionUiState.disconnected => l10n.connStateDisconnected,
      ConnectionUiState.awaitingAuthorization => l10n.connStateAwaiting,
      ConnectionUiState.connected => l10n.connStateConnected,
      ConnectionUiState.error => l10n.connStateError,
      ConnectionUiState.unavailable => l10n.connStateUnavailable,
    };

/// Badge tone and icon per state: never colour alone.
(Tone, IconData) connectionStateStyle(ConnectionUiState s) => switch (s) {
  ConnectionUiState.disconnected => (Tone.neutral, AppIcons.circle),
  ConnectionUiState.awaitingAuthorization => (
    Tone.info,
    AppIcons.clockCounterClockwise,
  ),
  ConnectionUiState.connected => (Tone.success, AppIcons.checkCircle),
  ConnectionUiState.error => (Tone.danger, AppIcons.warning),
  ConnectionUiState.unavailable => (Tone.warning, AppIcons.prohibit),
};

/// What the seller can expect from an account in this state.
String? connectionStateBody(AppLocalizations l10n, ConnectionUiState s) =>
    switch (s) {
      ConnectionUiState.awaitingAuthorization => l10n.connAwaitingBody,
      ConnectionUiState.error => l10n.connErrorBody,
      ConnectionUiState.unavailable => l10n.connUnavailableBody,
      _ => null,
    };

String deliveryLabel(AppLocalizations l10n, DeliveryState d) => switch (d) {
  DeliveryState.queued => l10n.deliveryQueued,
  DeliveryState.sending => l10n.deliverySending,
  DeliveryState.sent => l10n.deliverySent,
  DeliveryState.delivered => l10n.deliveryDelivered,
  DeliveryState.read => l10n.deliveryRead,
  DeliveryState.failed => l10n.deliveryFailed,
  DeliveryState.unknown => l10n.deliveryUnknown,
  DeliveryState.cancelled => l10n.deliveryCancelled,
};

(Tone, IconData) deliveryStyle(DeliveryState d) => switch (d) {
  DeliveryState.queued => (Tone.neutral, AppIcons.clockCounterClockwise),
  DeliveryState.sending => (Tone.info, AppIcons.arrowRight),
  DeliveryState.sent => (Tone.neutral, AppIcons.check),
  DeliveryState.delivered => (Tone.success, AppIcons.checkCircle),
  DeliveryState.read => (Tone.success, AppIcons.eye),
  DeliveryState.failed => (Tone.danger, AppIcons.xCircle),
  DeliveryState.unknown => (Tone.warning, AppIcons.question),
  DeliveryState.cancelled => (Tone.neutral, AppIcons.prohibit),
};

/// Why a send failed, from the server's safe error code (never provider
/// wording).
String sendFailureText(AppLocalizations l10n, String? code) => switch (code) {
  'window_closed' => l10n.errWindowClosed,
  'recipient_unavailable' => l10n.errContactUnavailable,
  'token_invalid' || 'permission_missing' => l10n.connErrorBody,
  'account_restricted' => l10n.failAccountRestricted,
  'templates_unsupported' || 'template_unavailable' => l10n.failTemplate,
  'marketing_limit' => l10n.failMarketingLimit,
  _ when code != null && code.startsWith('rate_limited') =>
    l10n.failRateLimited,
  _ => l10n.failProviderRefused,
};

/// Errors of connecting and sending (P-ERR-ACTION).
String channelErrorText(AppLocalizations l10n, ApiException e) =>
    switch (e.code) {
      ApiErrorCode.replyWindowClosed => l10n.errWindowClosed,
      ApiErrorCode.channelUnavailable => l10n.errChannelUnavailable,
      ApiErrorCode.contactUnavailable => l10n.errContactUnavailable,
      ApiErrorCode.sendStateChanged => l10n.errSendStateChanged,
      ApiErrorCode.tokenRejected => l10n.errTokenRejected,
      ApiErrorCode.accountInUse => l10n.errAccountInUse,
      ApiErrorCode.connectFailed => l10n.errConnectFailed,
      ApiErrorCode.validationFailed when e.fields.containsKey('params') =>
        l10n.templateParamInvalid,
      ApiErrorCode.forbidden => l10n.errOwnerOnly,
      ApiErrorCode.notFound => l10n.conversationUnavailable,
      ApiErrorCode.validationFailed when e.fields.values.contains('too_long') =>
        l10n.errMessageTooLong,
      _ => apiErrorText(l10n, e),
    };
