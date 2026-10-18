import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/api.dart';
import '../domain/channel.dart';

/// Connected messaging accounts and sending through them (Phase 9). Every
/// call runs with the seller's own session; the database authorizes it. The
/// app never holds a provider token: bot tokens go straight to the
/// `channel-connect` function (which stores them in Vault), and OAuth runs in
/// the provider's page in the browser.
abstract interface class ChannelsRepository {
  Future<List<ChannelProvider>> providers(String storeId);

  Future<List<ChannelConnection>> connections(String storeId);

  /// A single-use, 10-minute connect nonce bound to the store.
  Future<String> beginConnect(String storeId, String provider);

  /// Telegram / Viber: the provider confirms the bot behind [token].
  Future<void> connectBot(String provider, String nonce, String token);

  /// Meta / TikTok: the provider page to open in the browser.
  Future<Uri> authorizationUrl(String provider, String nonce);

  Future<void> disconnect(String storeId, String connectionId);

  /// Authorizes the exact [text] (server hashes and audits it).
  Future<SendReceipt> send(
    String storeId,
    String conversationId,
    String text, {
    String? suggestionId,
    String kind = 'reply',
    String? orderId,
    required String idempotencyKey,
  });

  /// Asks the `channel-send` function to submit an authorized send now. The
  /// background worker submits it otherwise, so a failure here is harmless.
  Future<void> dispatch(String sendRequestId);

  Future<TemplateList> templates(String storeId, String conversationId);

  Future<SendReceipt> sendTemplate(
    String storeId,
    String conversationId,
    String templateId,
    List<String> params, {
    required String idempotencyKey,
  });

  Future<void> cancelSend(String storeId, String sendRequestId);

  /// [resolution]: `mark_sent` (the seller saw it arrive) or `send_again`.
  /// Returns the new send's id for `send_again`.
  Future<String?> resolveUnknown(
    String storeId,
    String sendRequestId,
    String resolution, {
    required String idempotencyKey,
  });

  /// The server-generated confirmation text of an approved order.
  Future<String> confirmationText(String storeId, String orderId, String lang);
}

final channelsRepositoryProvider = Provider<ChannelsRepository>(
  (ref) => SupabaseChannelsRepository(ref.watch(supabaseClientProvider)),
);

/// Connect calls wait for the provider (identify the bot, register the
/// webhook).
const connectTimeout = Duration(seconds: 30);

class SupabaseChannelsRepository implements ChannelsRepository {
  SupabaseChannelsRepository(this._client);

  final SupabaseClient _client;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> params) =>
      callApi(_client, fn, params: params);

  Future<Map<String, dynamic>> _function(
    String name,
    Map<String, dynamic> body, {
    Duration timeout = connectTimeout,
  }) async {
    final Object? raw;
    try {
      raw = (await _client.functions.invoke(name, body: body).timeout(timeout))
          .data;
    } on TimeoutException {
      throw const ApiException(ApiErrorCode.timeout);
    } on FunctionException catch (e) {
      throw mapFunctionException(e, fallback: ApiErrorCode.connectFailed);
    } on AuthException {
      throw const ApiException(ApiErrorCode.unauthenticated);
    } on Exception {
      throw const ApiException(ApiErrorCode.network);
    }
    return unwrapEnvelope(raw is String ? jsonDecode(raw) : raw);
  }

  @override
  Future<List<ChannelProvider>> providers(String storeId) async => [
    for (final p
        in (await _call('list_channel_providers', {
                  'p_store_id': storeId,
                }))['items']
                as List? ??
            const [])
      ChannelProvider.fromJson((p as Map).cast<String, dynamic>()),
  ];

  @override
  Future<List<ChannelConnection>> connections(String storeId) async => [
    for (final c
        in (await _call('list_connections', {'p_store_id': storeId}))['items']
                as List? ??
            const [])
      ChannelConnection.fromJson((c as Map).cast<String, dynamic>()),
  ];

  @override
  Future<String> beginConnect(String storeId, String provider) async =>
      (await _call('begin_channel_connect', {
            'p_store_id': storeId,
            'p_provider': provider,
          }))['nonce']
          as String;

  @override
  Future<void> connectBot(String provider, String nonce, String token) =>
      _function('channel-connect', {
        'provider': provider,
        'nonce': nonce,
        'token': token,
      });

  @override
  Future<Uri> authorizationUrl(String provider, String nonce) async {
    final data = await _function('channel-oauth/start', {
      'provider': provider,
      'nonce': nonce,
    });
    final url = Uri.tryParse(data['url'] as String? ?? '');
    // Only an https page is ever opened.
    if (url == null || url.scheme != 'https') {
      throw const ApiException(ApiErrorCode.connectFailed);
    }
    return url;
  }

  @override
  Future<void> disconnect(String storeId, String connectionId) => _call(
    'disconnect_channel',
    {'p_store_id': storeId, 'p_connection_id': connectionId},
  );

  @override
  Future<SendReceipt> send(
    String storeId,
    String conversationId,
    String text, {
    String? suggestionId,
    String kind = 'reply',
    String? orderId,
    required String idempotencyKey,
  }) async => SendReceipt.fromJson(
    await _call('send_message', {
      'p_store_id': storeId,
      'p_conversation_id': conversationId,
      'p_text': text,
      'p_suggestion_id': suggestionId,
      'p_kind': kind,
      'p_order_id': orderId,
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<void> dispatch(String sendRequestId) => _function('channel-send', {
    'send_request_id': sendRequestId,
  }, timeout: const Duration(seconds: 25));

  @override
  Future<TemplateList> templates(String storeId, String conversationId) async =>
      TemplateList.fromJson(
        await _call('list_templates', {
          'p_store_id': storeId,
          'p_conversation_id': conversationId,
        }),
      );

  @override
  Future<SendReceipt> sendTemplate(
    String storeId,
    String conversationId,
    String templateId,
    List<String> params, {
    required String idempotencyKey,
  }) async => SendReceipt.fromJson(
    await _call('send_template', {
      'p_store_id': storeId,
      'p_conversation_id': conversationId,
      'p_template_id': templateId,
      'p_params': params,
      'p_idempotency_key': idempotencyKey,
    }),
  );

  @override
  Future<void> cancelSend(String storeId, String sendRequestId) => _call(
    'cancel_send',
    {'p_store_id': storeId, 'p_send_request_id': sendRequestId},
  );

  @override
  Future<String?> resolveUnknown(
    String storeId,
    String sendRequestId,
    String resolution, {
    required String idempotencyKey,
  }) async =>
      (await _call('resolve_unknown_send', {
            'p_store_id': storeId,
            'p_send_request_id': sendRequestId,
            'p_resolution': resolution,
            'p_idempotency_key': idempotencyKey,
          }))['new_send_request_id']
          as String?;

  @override
  Future<String> confirmationText(
    String storeId,
    String orderId,
    String lang,
  ) async =>
      (await _call('order_confirmation_text', {
            'p_store_id': storeId,
            'p_order_id': orderId,
            'p_lang': lang,
          }))['text']
          as String;
}
