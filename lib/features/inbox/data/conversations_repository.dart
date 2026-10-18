import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/api.dart';
import '../domain/conversation.dart';

/// Conversations, the AI assistant and written policies (Phase 8). Every call
/// is authorised by the database with the seller's own session. The AI runs
/// on the server (`ai-assist` Edge Function); the app never talks to a model
/// provider and holds no provider key.
abstract interface class ConversationsRepository {
  Future<ConversationPage> list(
    String storeId,
    InboxFilter filter, {
    int offset = 0,
    int limit = 30,
  });

  Future<Conversation> get(String storeId, String conversationId);

  /// Returns the new conversation's id.
  Future<String> create(
    String storeId, {
    required ConversationSource source,
    String? customerLabel,
    required List<ImportedMessage> messages,
    required String idempotencyKey,
  });

  Future<void> importMessages(
    String storeId,
    String conversationId,
    List<ImportedMessage> messages, {
    required String idempotencyKey,
  });

  /// A reply the seller wrote and sent themselves (outside Aisellia).
  Future<void> recordSellerReply(
    String storeId,
    String conversationId,
    String body, {
    required String idempotencyKey,
  });

  /// [status]: needs_reply, waiting or closed; [aiPaused]; [customerLabel].
  Future<void> update(
    String storeId,
    String conversationId, {
    required int expectedVersion,
    ConversationStatus? status,
    bool? aiPaused,
    String? customerLabel,
  });

  /// Asks the AI assistant for a suggested reply (and, for buying intent or
  /// [draft], an order draft). One key per user intent: a retry with the
  /// same key never calls the model twice.
  Future<AssistOutcome> requestAssist(
    String storeId,
    String conversationId, {
    bool draft = false,
    required String idempotencyKey,
  });

  /// Records the (possibly edited) suggestion as copied by the seller.
  /// Returns the message id.
  Future<String> copySuggestion(
    String storeId,
    String suggestionId, {
    String? editedText,
    required String idempotencyKey,
  });

  Future<void> markSent(String storeId, String messageId);

  Future<void> dismissSuggestion(String storeId, String suggestionId);

  Future<void> deleteConversation(String storeId, String conversationId);

  Future<AiSettings> aiSettings(String storeId);

  Future<void> setAiEnabled(String storeId, bool enabled);

  Future<StorePolicy> upsertPolicy(
    String storeId, {
    String? policyId,
    int? expectedVersion,
    required PolicyTopic topic,
    required String body,
    bool active = true,
    required String idempotencyKey,
  });

  Future<void> deletePolicy(
    String storeId,
    String policyId, {
    required int expectedVersion,
  });
}

final conversationsRepositoryProvider = Provider<ConversationsRepository>(
  (ref) => SupabaseConversationsRepository(ref.watch(supabaseClientProvider)),
);

/// The AI call waits for the model (server budget about 45 s).
const assistTimeout = Duration(seconds: 60);

class SupabaseConversationsRepository implements ConversationsRepository {
  SupabaseConversationsRepository(this._client);

  final SupabaseClient _client;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> params) =>
      callApi(_client, fn, params: params);

  List<Map<String, String>> _messages(List<ImportedMessage> m) => [
    for (final x in m) {'direction': x.inbound ? 'in' : 'out', 'body': x.body},
  ];

  @override
  Future<ConversationPage> list(
    String storeId,
    InboxFilter filter, {
    int offset = 0,
    int limit = 30,
  }) async => ConversationPage.fromJson(
    await _call('list_conversations', {
      'p_store_id': storeId,
      'p_filter': filter.wire,
      'p_limit': limit,
      'p_offset': offset,
    }),
  );

  @override
  Future<Conversation> get(String storeId, String conversationId) async =>
      Conversation.fromJson(
        await _call('get_conversation', {
          'p_store_id': storeId,
          'p_conversation_id': conversationId,
        }),
      );

  @override
  Future<String> create(
    String storeId, {
    required ConversationSource source,
    String? customerLabel,
    required List<ImportedMessage> messages,
    required String idempotencyKey,
  }) async {
    final data = await _call('create_conversation', {
      'p_store_id': storeId,
      'p_source': source.wire,
      'p_customer_label': customerLabel,
      'p_messages': _messages(messages),
      'p_idempotency_key': idempotencyKey,
    });
    return data['id'] as String;
  }

  @override
  Future<void> importMessages(
    String storeId,
    String conversationId,
    List<ImportedMessage> messages, {
    required String idempotencyKey,
  }) => _call('import_messages', {
    'p_store_id': storeId,
    'p_conversation_id': conversationId,
    'p_messages': _messages(messages),
    'p_idempotency_key': idempotencyKey,
  });

  @override
  Future<void> recordSellerReply(
    String storeId,
    String conversationId,
    String body, {
    required String idempotencyKey,
  }) => _call('record_seller_reply', {
    'p_store_id': storeId,
    'p_conversation_id': conversationId,
    'p_body': body,
    'p_idempotency_key': idempotencyKey,
  });

  @override
  Future<void> update(
    String storeId,
    String conversationId, {
    required int expectedVersion,
    ConversationStatus? status,
    bool? aiPaused,
    String? customerLabel,
  }) => _call('update_conversation', {
    'p_store_id': storeId,
    'p_conversation_id': conversationId,
    'p_expected_version': expectedVersion,
    'p_fields': {
      'status': ?status?.wire,
      'ai_paused': ?aiPaused,
      'customer_label': ?customerLabel,
    },
  });

  @override
  Future<AssistOutcome> requestAssist(
    String storeId,
    String conversationId, {
    bool draft = false,
    required String idempotencyKey,
  }) async {
    final Object? raw;
    try {
      final res = await _client.functions
          .invoke(
            'ai-assist',
            body: {
              'store_id': storeId,
              'conversation_id': conversationId,
              'mode': draft ? 'draft' : 'reply',
              'idempotency_key': idempotencyKey,
            },
          )
          .timeout(assistTimeout);
      raw = res.data;
    } on TimeoutException {
      throw const ApiException(ApiErrorCode.timeout);
    } on FunctionException catch (e) {
      throw mapFunctionException(e, fallback: ApiErrorCode.aiUnavailable);
    } on AuthException {
      throw const ApiException(ApiErrorCode.unauthenticated);
    } on Exception {
      throw const ApiException(ApiErrorCode.network);
    }
    return AssistOutcome.fromJson(
      unwrapEnvelope(raw is String ? jsonDecode(raw) : raw),
    );
  }

  @override
  Future<String> copySuggestion(
    String storeId,
    String suggestionId, {
    String? editedText,
    required String idempotencyKey,
  }) async {
    final data = await _call('copy_suggestion', {
      'p_store_id': storeId,
      'p_suggestion_id': suggestionId,
      'p_text': editedText,
      'p_idempotency_key': idempotencyKey,
    });
    return data['message_id'] as String;
  }

  @override
  Future<void> markSent(String storeId, String messageId) => _call(
    'mark_message_sent',
    {'p_store_id': storeId, 'p_message_id': messageId},
  );

  @override
  Future<void> dismissSuggestion(String storeId, String suggestionId) => _call(
    'dismiss_suggestion',
    {'p_store_id': storeId, 'p_suggestion_id': suggestionId},
  );

  @override
  Future<void> deleteConversation(String storeId, String conversationId) =>
      _call('delete_conversation', {
        'p_store_id': storeId,
        'p_conversation_id': conversationId,
      });

  @override
  Future<AiSettings> aiSettings(String storeId) async {
    final data = await _call('list_policies', {'p_store_id': storeId});
    return AiSettings(
      enabled: data['ai_enabled'] != false,
      policies: [
        for (final p in data['items'] as List? ?? const [])
          StorePolicy.fromJson((p as Map).cast<String, dynamic>()),
      ],
    );
  }

  @override
  Future<void> setAiEnabled(String storeId, bool enabled) =>
      _call('set_ai_enabled', {'p_store_id': storeId, 'p_enabled': enabled});

  @override
  Future<StorePolicy> upsertPolicy(
    String storeId, {
    String? policyId,
    int? expectedVersion,
    required PolicyTopic topic,
    required String body,
    bool active = true,
    required String idempotencyKey,
  }) async => StorePolicy.fromJson(
    await _call('upsert_policy', {
      'p_store_id': storeId,
      'p_policy_id': policyId,
      'p_expected_version': expectedVersion,
      'p_topic': topic.name,
      'p_body': body,
      'p_active': active,
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<void> deletePolicy(
    String storeId,
    String policyId, {
    required int expectedVersion,
  }) => _call('delete_policy', {
    'p_store_id': storeId,
    'p_policy_id': policyId,
    'p_expected_version': expectedVersion,
  });
}
