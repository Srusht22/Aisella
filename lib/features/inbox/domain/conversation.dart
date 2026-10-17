import 'package:flutter/foundation.dart';

import '../../../core/formatting/money.dart';
import '../../orders/domain/order.dart' show Actor, OrderIssue, OrderStatus;

/// Where a conversation came from. No channel is connected in Phase 8: every
/// conversation is pasted in by the seller (labelled with its source) or is a
/// sandbox test (Phase 1 §4.2, US-020/021).
enum ConversationSource {
  instagram,
  whatsapp,
  messenger,
  telegram,
  phone,
  other,
  sandbox;

  static ConversationSource parse(Object? v) => values.firstWhere(
    (s) => s.name == v,
    orElse: () => ConversationSource.other,
  );

  String get wire => name;
}

/// Inbox status (US-022). "Needs you" is set only by escalation.
enum ConversationStatus {
  needsReply,
  needsYou,
  waiting,
  closed;

  static ConversationStatus parse(Object? v) => switch (v) {
    'needs_you' => ConversationStatus.needsYou,
    'waiting' => ConversationStatus.waiting,
    'closed' => ConversationStatus.closed,
    _ => ConversationStatus.needsReply,
  };

  String get wire => switch (this) {
    ConversationStatus.needsReply => 'needs_reply',
    ConversationStatus.needsYou => 'needs_you',
    ConversationStatus.waiting => 'waiting',
    ConversationStatus.closed => 'closed',
  };
}

/// Inbox filter chips.
enum InboxFilter {
  open('open'),
  needsYou('needs_you'),
  needsReply('needs_reply'),
  waiting('waiting'),
  closed('closed'),
  sandbox('sandbox');

  const InboxFilter(this.wire);
  final String wire;
}

/// Who wrote a message and what is known about it having been sent. Nothing
/// is ever "sent" by Aisellia in Phase 8 (BR-45–49).
enum MessageOrigin {
  /// Pasted by the seller (customer text, or the seller's earlier reply).
  imported,

  /// Written by the seller and marked as sent by them.
  sellerWritten,

  /// An AI suggestion the seller copied (and possibly edited).
  aiReplyCopied;

  static MessageOrigin parse(Object? v) => switch (v) {
    'seller_written' => MessageOrigin.sellerWritten,
    'ai_reply_copied' => MessageOrigin.aiReplyCopied,
    _ => MessageOrigin.imported,
  };
}

enum MessageState {
  imported,

  /// "Copied — not confirmed as sent".
  copied,

  /// "Marked as sent by you".
  markedSent;

  static MessageState parse(Object? v) => switch (v) {
    'copied' => MessageState.copied,
    'marked_sent' => MessageState.markedSent,
    _ => MessageState.imported,
  };
}

@immutable
class Message {
  const Message({
    required this.id,
    required this.inbound,
    required this.origin,
    required this.state,
    required this.createdAt,
    this.body,
    this.edited = false,
    this.author,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    id: j['id'] as String,
    inbound: j['direction'] == 'in',
    origin: MessageOrigin.parse(j['origin']),
    state: MessageState.parse(j['state']),
    body: j['body'] as String?,
    edited: j['edited'] == true,
    author: j['author'] == null ? null : Actor.parse(j['author']),
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
  );

  final String id;

  /// From the customer (true) or from the seller's side (false).
  final bool inbound;
  final MessageOrigin origin;
  final MessageState state;

  /// Null once the retention period removed the text.
  final String? body;
  final bool edited;
  final Actor? author;
  final DateTime createdAt;
}

/// A value the server rendered into a suggestion from the store's records.
@immutable
class FactUsed {
  const FactUsed({required this.fact, required this.label, this.value});

  factory FactUsed.fromJson(Map<String, dynamic> j) => FactUsed(
    fact: j['fact'] as String? ?? '',
    label: j['label'] as String? ?? '',
    value: j['value'] as String?,
  );

  /// variant_price, variant_availability, zone_fee, policy_text, …
  final String fact;

  /// What it refers to (product / variant, zone or policy topic).
  final String label;

  /// The rendered value (for example "35,000 IQD").
  final String? value;
}

enum SuggestionStatus {
  suggested,
  copied,
  dismissed,
  superseded;

  static SuggestionStatus parse(Object? v) => values.firstWhere(
    (s) => s.name == v,
    orElse: () => SuggestionStatus.suggested,
  );
}

/// An AI reply proposal: never itself a message (Phase 3 AI §10, level 1).
@immutable
class Suggestion {
  const Suggestion({
    required this.id,
    required this.intent,
    required this.language,
    required this.status,
    required this.createdAt,
    this.text,
    this.factsUsed = const [],
    this.missingFields = const [],
    this.escalationReasons = const [],
    this.conflicts = const [],
    this.flags = const [],
    this.isHolding = false,
    this.messageId,
  });

  factory Suggestion.fromJson(Map<String, dynamic> j) => Suggestion(
    id: j['id'] as String,
    intent: j['intent'] as String? ?? 'other',
    language: j['reply_language'] as String? ?? 'en',
    status: SuggestionStatus.parse(j['status']),
    text: j['text'] as String?,
    factsUsed: [
      for (final f in j['facts_used'] as List? ?? const [])
        if (f is Map) FactUsed.fromJson(f.cast<String, dynamic>()),
    ],
    missingFields: [
      ...(j['missing_fields'] as List? ?? const []).cast<String>(),
    ],
    escalationReasons: [
      ...(j['escalation_reasons'] as List? ?? const []).cast<String>(),
    ],
    conflicts: [
      for (final c in j['conflicts'] as List? ?? const [])
        if (c is Map && c['field'] is String) c['field'] as String,
    ],
    flags: [...(j['flags'] as List? ?? const []).cast<String>()],
    isHolding: j['is_holding'] == true,
    messageId: j['message_id'] as String?,
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
  );

  final String id;
  final String intent;

  /// ckb, ar or en: the customer's language, not the app's.
  final String language;
  final SuggestionStatus status;

  /// Null once the retention period removed the text.
  final String? text;
  final List<FactUsed> factsUsed;
  final List<String> missingFields;
  final List<String> escalationReasons;

  /// Fields the customer gave contradictory values for.
  final List<String> conflicts;

  /// Server checks that replaced the model's text (money, claim, …).
  final List<String> flags;

  /// The server's neutral holding reply (escalated, or the model's text was
  /// not safe to suggest).
  final bool isHolding;
  final String? messageId;
  final DateTime createdAt;

  bool get escalated => escalationReasons.isNotEmpty;

  /// Right-to-left reply text (Sorani or Arabic).
  bool get rtl => language == 'ckb' || language == 'ar';
}

enum AiRunStatus {
  queued,
  running,
  succeeded,
  invalidOutput,
  timeout,
  providerError,
  refused,
  rateLimited,
  expired,
  skipped;

  static AiRunStatus parse(Object? v) => switch (v) {
    'queued' => AiRunStatus.queued,
    'running' => AiRunStatus.running,
    'succeeded' => AiRunStatus.succeeded,
    'invalid_output' => AiRunStatus.invalidOutput,
    'timeout' => AiRunStatus.timeout,
    'refused' => AiRunStatus.refused,
    'rate_limited' => AiRunStatus.rateLimited,
    'expired' => AiRunStatus.expired,
    'skipped' => AiRunStatus.skipped,
    _ => AiRunStatus.providerError,
  };

  bool get failed =>
      this != AiRunStatus.queued &&
      this != AiRunStatus.running &&
      this != AiRunStatus.succeeded;
}

@immutable
class AiRunInfo {
  const AiRunInfo({required this.id, required this.status, this.errorCode});

  factory AiRunInfo.fromJson(Map<String, dynamic> j) => AiRunInfo(
    id: j['id'] as String? ?? j['run_id'] as String? ?? '',
    status: AiRunStatus.parse(j['status']),
    errorCode: j['error_code'] as String?,
  );

  final String id;
  final AiRunStatus status;
  final String? errorCode;
}

/// The AI draft created from a conversation (level 2: not confirmed).
@immutable
class ConversationOrder {
  const ConversationOrder({
    required this.id,
    required this.number,
    required this.status,
    required this.isTest,
    this.total,
    this.currency = Currency.iqd,
    this.issues = const [],
  });

  factory ConversationOrder.fromJson(Map<String, dynamic> j) =>
      ConversationOrder(
        id: j['id'] as String,
        number: (j['number'] as num).toInt(),
        status: OrderStatus.parse(j['status']),
        isTest: j['is_test'] == true,
        total: (j['total'] as num?)?.toInt(),
        currency: j['currency'] == 'USD' ? Currency.usd : Currency.iqd,
        issues: [
          for (final i in j['issues'] as List? ?? const [])
            if (i is Map) OrderIssue.fromJson(i.cast<String, dynamic>()),
        ],
      );

  final String id;
  final int number;
  final OrderStatus status;
  final bool isTest;
  final int? total;
  final Currency currency;
  final List<OrderIssue> issues;
}

/// One row of the inbox (US-022).
@immutable
class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.source,
    required this.status,
    required this.lastActivityAt,
    required this.version,
    this.customerLabel,
    this.escalationReasons = const [],
    this.aiPaused = false,
    this.lastPreview,
    this.lastInbound = true,
    this.order,
  });

  factory ConversationSummary.fromJson(Map<String, dynamic> j) {
    final last = j['last_message'];
    return ConversationSummary(
      id: j['id'] as String,
      customerLabel: j['customer_label'] as String?,
      source: ConversationSource.parse(j['source']),
      status: ConversationStatus.parse(j['status']),
      escalationReasons: [
        ...(j['escalation_reasons'] as List? ?? const []).cast<String>(),
      ],
      aiPaused: j['ai_paused'] == true,
      lastPreview: last is Map ? last['preview'] as String? : null,
      lastInbound: last is Map ? last['direction'] == 'in' : true,
      order: j['order'] is Map
          ? ConversationOrder.fromJson((j['order'] as Map).cast())
          : null,
      lastActivityAt: DateTime.parse(j['last_activity_at'] as String).toLocal(),
      version: (j['version'] as num).toInt(),
    );
  }

  final String id;
  final String? customerLabel;
  final ConversationSource source;
  final ConversationStatus status;
  final List<String> escalationReasons;
  final bool aiPaused;
  final String? lastPreview;
  final bool lastInbound;
  final ConversationOrder? order;
  final DateTime lastActivityAt;
  final int version;

  bool get isSandbox => source == ConversationSource.sandbox;
}

/// The conversation screen's data: messages, the current suggestion, the last
/// AI run, the linked draft and the store's AI usage.
@immutable
class Conversation {
  const Conversation({
    required this.summary,
    required this.messages,
    required this.aiEnabled,
    required this.callsToday,
    required this.dailyLimit,
    this.missingFields = const [],
    this.suggestion,
    this.lastRun,
  });

  factory Conversation.fromJson(Map<String, dynamic> j) {
    final ai = (j['ai'] as Map? ?? const {}).cast<String, dynamic>();
    return Conversation(
      summary: ConversationSummary.fromJson(j),
      messages: [
        for (final m in j['messages'] as List? ?? const [])
          Message.fromJson((m as Map).cast<String, dynamic>()),
      ],
      missingFields: [
        ...(j['missing_fields'] as List? ?? const []).cast<String>(),
      ],
      suggestion: j['suggestion'] is Map
          ? Suggestion.fromJson((j['suggestion'] as Map).cast())
          : null,
      lastRun: j['last_run'] is Map
          ? AiRunInfo.fromJson((j['last_run'] as Map).cast())
          : null,
      aiEnabled: ai['enabled'] != false,
      callsToday: (ai['calls_today'] as num?)?.toInt() ?? 0,
      dailyLimit: (ai['daily_limit'] as num?)?.toInt() ?? 0,
    );
  }

  final ConversationSummary summary;
  final List<Message> messages;
  final List<String> missingFields;
  final Suggestion? suggestion;
  final AiRunInfo? lastRun;
  final bool aiEnabled;
  final int callsToday;
  final int dailyLimit;

  String get id => summary.id;
  ConversationOrder? get order => summary.order;
  bool get hasCustomerMessage =>
      messages.any((m) => m.inbound && m.body != null);
}

@immutable
class ConversationPage {
  const ConversationPage({
    required this.items,
    required this.total,
    required this.hasMore,
    this.needsYou = 0,
    this.needsReply = 0,
    this.waiting = 0,
  });

  factory ConversationPage.fromJson(Map<String, dynamic> j) {
    final counts = (j['counts'] as Map? ?? const {}).cast<String, dynamic>();
    int n(String k) => (counts[k] as num?)?.toInt() ?? 0;
    return ConversationPage(
      items: [
        for (final i in j['items'] as List? ?? const [])
          ConversationSummary.fromJson((i as Map).cast<String, dynamic>()),
      ],
      total: (j['total'] as num?)?.toInt() ?? 0,
      hasMore: j['has_more'] == true,
      needsYou: n('needs_you'),
      needsReply: n('needs_reply'),
      waiting: n('waiting'),
    );
  }

  final List<ConversationSummary> items;
  final int total;
  final bool hasMore;
  final int needsYou;
  final int needsReply;
  final int waiting;
}

/// A message to import: the customer's (inbound) or the seller's own earlier
/// reply (outbound), as pasted.
typedef ImportedMessage = ({bool inbound, String body});

/// The outcome of asking the AI assistant for help.
@immutable
class AssistOutcome {
  const AssistOutcome({
    required this.runId,
    required this.status,
    this.errorCode,
    this.escalated = false,
    this.orderId,
  });

  factory AssistOutcome.fromJson(Map<String, dynamic> j) => AssistOutcome(
    runId: j['run_id'] as String? ?? '',
    status: AiRunStatus.parse(
      j['status'] == 'not_claimed' ? 'expired' : j['status'],
    ),
    errorCode: j['error_code'] as String?,
    escalated: j['escalated'] == true,
    orderId: j['order_id'] as String?,
  );

  final String runId;
  final AiRunStatus status;
  final String? errorCode;
  final bool escalated;
  final String? orderId;
}

enum PolicyTopic {
  delivery,
  returns,
  exchange,
  payment,
  warranty,
  hours,
  other;

  static PolicyTopic parse(Object? v) =>
      values.firstWhere((t) => t.name == v, orElse: () => PolicyTopic.other);
}

/// A seller-written policy: the only source for policy answers (§8.2).
@immutable
class StorePolicy {
  const StorePolicy({
    required this.id,
    required this.topic,
    required this.body,
    required this.active,
    required this.version,
  });

  factory StorePolicy.fromJson(Map<String, dynamic> j) => StorePolicy(
    id: j['id'] as String,
    topic: PolicyTopic.parse(j['topic']),
    body: j['body'] as String? ?? '',
    active: j['active'] != false,
    version: (j['version'] as num).toInt(),
  );

  final String id;
  final PolicyTopic topic;
  final String body;
  final bool active;
  final int version;
}

@immutable
class AiSettings {
  const AiSettings({required this.enabled, required this.policies});

  final bool enabled;
  final List<StorePolicy> policies;
}
