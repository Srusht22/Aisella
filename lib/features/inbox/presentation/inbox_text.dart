import '../../../core/backend/api.dart';
import '../../../core/l10n/l10n.dart';
import '../../common/api_error_text.dart';
import '../domain/conversation.dart';

String sourceLabel(AppLocalizations l10n, ConversationSource s) => switch (s) {
  ConversationSource.instagram => l10n.sourceInstagram,
  ConversationSource.whatsapp => l10n.sourceWhatsapp,
  ConversationSource.messenger => l10n.sourceMessenger,
  ConversationSource.telegram => l10n.sourceTelegram,
  ConversationSource.phone => l10n.sourcePhone,
  ConversationSource.other => l10n.sourceOther,
  ConversationSource.sandbox => l10n.sourceSandbox,
};

String conversationStatusLabel(AppLocalizations l10n, ConversationStatus s) =>
    switch (s) {
      ConversationStatus.needsReply => l10n.convNeedsReply,
      ConversationStatus.needsYou => l10n.convNeedsYou,
      ConversationStatus.waiting => l10n.convWaiting,
      ConversationStatus.closed => l10n.convClosed,
    };

String inboxFilterLabel(AppLocalizations l10n, InboxFilter f) => switch (f) {
  InboxFilter.open => l10n.inboxFilterOpen,
  InboxFilter.needsYou => l10n.convNeedsYou,
  InboxFilter.needsReply => l10n.convNeedsReply,
  InboxFilter.waiting => l10n.convWaiting,
  InboxFilter.closed => l10n.convClosed,
  InboxFilter.sandbox => l10n.sourceSandbox,
};

/// Why the AI handed the conversation to the seller (Phase 1 §8.5).
String escalationLabel(AppLocalizations l10n, String reason) =>
    switch (reason) {
      'complaint' => l10n.escComplaint,
      'refund_or_dispute' => l10n.escRefund,
      'discount_request' => l10n.escDiscount,
      'health_or_safety' => l10n.escHealth,
      'authenticity_dispute' => l10n.escAuthenticity,
      'abuse' => l10n.escAbuse,
      'modify_approved_order' => l10n.escModifyApproved,
      'order_status' => l10n.escOrderStatus,
      'human_requested' => l10n.escHuman,
      'suspected_manipulation' => l10n.escManipulation,
      'unsupported_language' => l10n.escLanguage,
      'repeated_clarification_failed' => l10n.escRepeatedClarification,
      _ => l10n.escOutOfScope,
    };

/// What a rendered fact is (shown with its value under "Based on").
String factLabel(AppLocalizations l10n, FactUsed f) => switch (f.fact) {
  'variant_price' => l10n.factPrice(f.label),
  'variant_availability' => l10n.factAvailability(f.label),
  'zone_fee' => l10n.factDeliveryFee(f.label),
  'zone_time_text' => l10n.factDeliveryTime(f.label),
  'zone_name' => l10n.factZone,
  'policy_text' => l10n.factPolicy,
  'payment_methods' => l10n.factPayment,
  'store_name' => l10n.factStoreName,
  _ => l10n.factProduct,
};

String missingFieldLabel(AppLocalizations l10n, String field) =>
    switch (field) {
      'product' => l10n.missingProduct,
      'variant' => l10n.missingVariant,
      'quantity' => l10n.missingQuantity,
      'customer_name' => l10n.fieldName,
      'customer_phone' => l10n.fieldPhone,
      'zone' => l10n.fieldZone,
      'area' => l10n.fieldArea,
      'payment_method' => l10n.fieldPaymentMethod,
      _ => field,
    };

/// Why the server replaced the AI's text with the holding reply.
String? holdingReason(AppLocalizations l10n, Suggestion s) {
  if (!s.isHolding || s.escalated) return null;
  if (s.flags.contains('invalid_reference')) return l10n.holdingUnknownFact;
  return l10n.holdingUnsupportedClaim;
}

String messageStateLabel(AppLocalizations l10n, Message m) =>
    switch ((m.origin, m.state, m.inbound)) {
      (_, _, true) => l10n.msgFromCustomerPasted,
      (MessageOrigin.imported, _, false) => l10n.msgYourReplyPasted,
      (MessageOrigin.sellerWritten, _, _) => l10n.msgMarkedSentByYou,
      (MessageOrigin.aiReplyCopied, MessageState.copied, _) =>
        m.edited ? l10n.msgCopiedEdited : l10n.msgCopiedNotSent,
      (MessageOrigin.aiReplyCopied, _, _) =>
        m.edited ? l10n.msgSentEdited : l10n.msgMarkedSentByYou,
    };

/// The outcome of a run that did not produce a suggestion.
String runFailureText(AppLocalizations l10n, AiRunStatus s) => switch (s) {
  AiRunStatus.timeout => l10n.aiFailTimeout,
  AiRunStatus.rateLimited => l10n.aiFailBusy,
  AiRunStatus.refused => l10n.aiFailRefused,
  AiRunStatus.invalidOutput => l10n.aiFailInvalid,
  AiRunStatus.skipped => l10n.aiFailSkipped,
  AiRunStatus.expired => l10n.aiFailExpired,
  _ => l10n.aiFailUnavailable,
};

/// Errors of conversation and AI actions (P-ERR-ACTION).
String inboxErrorText(AppLocalizations l10n, ApiException e) =>
    switch (e.code) {
      ApiErrorCode.aiDisabled => l10n.errAiDisabled,
      ApiErrorCode.aiPaused => l10n.errAiPaused,
      ApiErrorCode.aiBusy => l10n.errAiBusy,
      ApiErrorCode.nothingToAnswer => l10n.errNothingToAnswer,
      ApiErrorCode.aiUnavailable => l10n.aiFailUnavailable,
      ApiErrorCode.rateLimited => l10n.errAiRateLimited,
      ApiErrorCode.suggestionClosed => l10n.errSuggestionClosed,
      ApiErrorCode.forbidden => l10n.errOwnerOnly,
      ApiErrorCode.notFound => l10n.conversationUnavailable,
      ApiErrorCode.validationFailed when e.fields.values.contains('too_long') =>
        l10n.errMessageTooLong,
      ApiErrorCode.limitExceeded => l10n.errTooManyMessages,
      _ => apiErrorText(l10n, e),
    };

String policyTopicLabel(AppLocalizations l10n, PolicyTopic t) => switch (t) {
  PolicyTopic.delivery => l10n.policyDelivery,
  PolicyTopic.returns => l10n.policyReturns,
  PolicyTopic.exchange => l10n.policyExchange,
  PolicyTopic.payment => l10n.policyPayment,
  PolicyTopic.warranty => l10n.policyWarranty,
  PolicyTopic.hours => l10n.policyHours,
  PolicyTopic.other => l10n.policyOther,
};
