import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/features/inbox/data/conversations_repository.dart';
import 'package:aisellia/features/inbox/domain/conversation.dart';

/// In-memory conversations with the server's rules the screens depend on:
/// statuses, copied → marked sent, suggestions superseded by a new run. The
/// AI itself is a scripted test double: [nextAssist] decides what a run
/// produces (a suggestion, an escalation, a failure). Records calls.
class FakeConversationsRepository implements ConversationsRepository {
  FakeConversationsRepository({List<Map<String, dynamic>>? conversations}) {
    for (final c in conversations ?? const <Map<String, dynamic>>[]) {
      _convs[c['id'] as String] = c;
    }
  }

  final _convs = <String, Map<String, dynamic>>{};
  final calls = <String>[];
  var _seq = 0;
  bool aiEnabled = true;
  final policies = <StorePolicy>[];

  /// What the next assist call does: returns the suggestion JSON to store
  /// (or null for none) and the run status; throwing simulates transport.
  ({Map<String, dynamic>? suggestion, String status, List<String> reasons})
  Function(String conversationId)?
  nextAssist;

  /// The next call fails with this error (then it is cleared).
  ApiException? failNext;

  String _id() => 'c-${++_seq}';

  void _maybeFail(String call) {
    calls.add(call);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  Map<String, dynamic> _conv(String id) =>
      _convs[id] ?? (throw const ApiException(ApiErrorCode.notFound));

  /// A conversation row as get_conversation returns it.
  static Map<String, dynamic> conversationJson({
    required String id,
    String? label,
    String source = 'instagram',
    String status = 'needs_reply',
    List<Map<String, dynamic>> messages = const [],
    Map<String, dynamic>? suggestion,
    Map<String, dynamic>? order,
    Map<String, dynamic>? lastRun,
    List<String> escalation = const [],
    bool aiPaused = false,
  }) => {
    'id': id,
    'customer_label': label,
    'source': source,
    'is_sandbox': source == 'sandbox',
    'status': status,
    'escalation_reasons': escalation,
    'ai_paused': aiPaused,
    'missing_fields': <String>[],
    'last_activity_at': '2026-10-15T09:00:00Z',
    'created_at': '2026-10-15T09:00:00Z',
    'version': 1,
    'last_message': messages.isEmpty
        ? null
        : {
            'direction': messages.last['direction'],
            'preview': messages.last['body'],
          },
    'messages': messages,
    'suggestion': suggestion,
    'order': order,
    'last_run': lastRun,
  };

  static Map<String, dynamic> messageJson(
    String id,
    String body, {
    bool inbound = true,
    String origin = 'imported',
    String state = 'imported',
  }) => {
    'id': id,
    'direction': inbound ? 'in' : 'out',
    'origin': origin,
    'body': body,
    'state': state,
    'edited': false,
    'created_at': '2026-10-15T09:00:00Z',
  };

  static Map<String, dynamic> suggestionJson({
    String id = 's-1',
    String text = 'The Beige Abaya in size M is available, price 35,000 IQD.',
    String language = 'en',
    String status = 'suggested',
    List<Map<String, dynamic>> facts = const [
      {
        'fact': 'variant_price',
        'label': 'Beige Abaya / M',
        'value': '35,000 IQD',
      },
    ],
    List<String> missing = const [],
    List<String> escalation = const [],
    List<String> flags = const [],
    bool holding = false,
  }) => {
    'id': id,
    'intent': 'price_inquiry',
    'reply_language': language,
    'text': text,
    'facts_used': facts,
    'missing_fields': missing,
    'escalation_reasons': escalation,
    'conflicts': <Map<String, dynamic>>[],
    'flags': flags,
    'is_holding': holding,
    'status': status,
    'created_at': '2026-10-15T09:00:00Z',
  };

  Map<String, dynamic> _withAi(Map<String, dynamic> c) => {
    ...c,
    'ai': {'enabled': aiEnabled, 'calls_today': 3, 'daily_limit': 300},
  };

  @override
  Future<ConversationPage> list(
    String storeId,
    InboxFilter filter, {
    int offset = 0,
    int limit = 30,
  }) async {
    _maybeFail('list');
    final items = _convs.values.where((c) {
      final sandbox = c['source'] == 'sandbox';
      return switch (filter) {
        InboxFilter.open => c['status'] != 'closed' && !sandbox,
        InboxFilter.sandbox => sandbox,
        _ => c['status'] == filter.wire && !sandbox,
      };
    }).toList();
    int n(String s) => _convs.values.where((c) => c['status'] == s).length;
    return ConversationPage.fromJson({
      'items': items,
      'total': items.length,
      'has_more': false,
      'counts': {
        'needs_you': n('needs_you'),
        'needs_reply': n('needs_reply'),
        'waiting': n('waiting'),
      },
    });
  }

  @override
  Future<Conversation> get(String storeId, String conversationId) async {
    _maybeFail('get');
    return Conversation.fromJson(_withAi(_conv(conversationId)));
  }

  @override
  Future<String> create(
    String storeId, {
    required ConversationSource source,
    String? customerLabel,
    required List<ImportedMessage> messages,
    required String idempotencyKey,
  }) async {
    _maybeFail('create');
    final id = _id();
    _convs[id] = conversationJson(
      id: id,
      label: customerLabel,
      source: source.wire,
      messages: [
        for (final m in messages)
          messageJson('m-${++_seq}', m.body, inbound: m.inbound),
      ],
    );
    return id;
  }

  @override
  Future<void> importMessages(
    String storeId,
    String conversationId,
    List<ImportedMessage> messages, {
    required String idempotencyKey,
  }) async {
    _maybeFail('import');
    final c = _conv(conversationId);
    c['messages'] = [
      ...c['messages'] as List,
      for (final m in messages)
        messageJson('m-${++_seq}', m.body, inbound: m.inbound),
    ];
    if (messages.any((m) => m.inbound)) c['status'] = 'needs_reply';
  }

  @override
  Future<void> recordSellerReply(
    String storeId,
    String conversationId,
    String body, {
    required String idempotencyKey,
  }) async {
    _maybeFail('reply');
    final c = _conv(conversationId);
    c['messages'] = [
      ...c['messages'] as List,
      messageJson(
        'm-${++_seq}',
        body,
        inbound: false,
        origin: 'seller_written',
        state: 'marked_sent',
      ),
    ];
    c['status'] = 'waiting';
  }

  @override
  Future<void> update(
    String storeId,
    String conversationId, {
    required int expectedVersion,
    ConversationStatus? status,
    bool? aiPaused,
    String? customerLabel,
  }) async {
    _maybeFail('update');
    final c = _conv(conversationId);
    if (status != null) {
      c['status'] = status.wire;
      c['escalation_reasons'] = <String>[];
    }
    if (aiPaused != null) c['ai_paused'] = aiPaused;
    c['version'] = (c['version'] as int) + 1;
  }

  @override
  Future<AssistOutcome> requestAssist(
    String storeId,
    String conversationId, {
    bool draft = false,
    required String idempotencyKey,
  }) async {
    _maybeFail(draft ? 'assist:draft' : 'assist');
    final c = _conv(conversationId);
    final script =
        nextAssist?.call(conversationId) ??
        (
          suggestion: suggestionJson(id: 's-${++_seq}'),
          status: 'succeeded',
          reasons: <String>[],
        );
    final runId = 'run-${++_seq}';
    c['last_run'] = {'id': runId, 'status': script.status};
    if (script.suggestion != null) c['suggestion'] = script.suggestion;
    if (script.reasons.isNotEmpty) {
      c['status'] = 'needs_you';
      c['escalation_reasons'] = script.reasons;
    }
    return AssistOutcome(
      runId: runId,
      status: AiRunStatus.parse(script.status),
      escalated: script.reasons.isNotEmpty,
    );
  }

  @override
  Future<String> copySuggestion(
    String storeId,
    String suggestionId, {
    String? editedText,
    required String idempotencyKey,
  }) async {
    _maybeFail('copy');
    final c = _convs.values.firstWhere(
      (c) => (c['suggestion'] as Map?)?['id'] == suggestionId,
    );
    final s = c['suggestion'] as Map<String, dynamic>;
    final id = 'm-${++_seq}';
    s['status'] = 'copied';
    s['message_id'] = id;
    c['messages'] = [
      ...c['messages'] as List,
      {
        ...messageJson(
          id,
          editedText ?? s['text'] as String,
          inbound: false,
          origin: 'ai_reply_copied',
          state: 'copied',
        ),
        'edited': editedText != null && editedText != s['text'],
      },
    ];
    return id;
  }

  @override
  Future<void> markSent(String storeId, String messageId) async {
    _maybeFail('sent');
    for (final c in _convs.values) {
      for (final m in (c['messages'] as List).cast<Map<String, dynamic>>()) {
        if (m['id'] == messageId) {
          m['state'] = 'marked_sent';
          c['status'] = 'waiting';
        }
      }
    }
  }

  @override
  Future<void> dismissSuggestion(String storeId, String suggestionId) async {
    _maybeFail('dismiss');
    for (final c in _convs.values) {
      if ((c['suggestion'] as Map?)?['id'] == suggestionId) {
        c['suggestion'] = null;
      }
    }
  }

  @override
  Future<void> deleteConversation(String storeId, String conversationId) async {
    _maybeFail('delete');
    _convs.remove(conversationId);
  }

  @override
  Future<AiSettings> aiSettings(String storeId) async {
    _maybeFail('settings');
    return AiSettings(enabled: aiEnabled, policies: List.of(policies));
  }

  @override
  Future<void> setAiEnabled(String storeId, bool enabled) async {
    _maybeFail('setAi');
    aiEnabled = enabled;
  }

  @override
  Future<StorePolicy> upsertPolicy(
    String storeId, {
    String? policyId,
    int? expectedVersion,
    required PolicyTopic topic,
    required String body,
    bool active = true,
    required String idempotencyKey,
  }) async {
    _maybeFail('policy');
    final p = StorePolicy(
      id: policyId ?? 'p-${++_seq}',
      topic: topic,
      body: body,
      active: active,
      version: (expectedVersion ?? 0) + 1,
    );
    policies
      ..removeWhere((x) => x.id == p.id)
      ..add(p);
    return p;
  }

  @override
  Future<void> deletePolicy(
    String storeId,
    String policyId, {
    required int expectedVersion,
  }) async {
    _maybeFail('deletePolicy');
    policies.removeWhere((x) => x.id == policyId);
  }
}
