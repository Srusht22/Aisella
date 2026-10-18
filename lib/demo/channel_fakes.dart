import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/features/channels/data/channels_repository.dart';
import 'package:aisellia/features/channels/domain/channel.dart';

import 'inbox_fakes.dart';

/// In-memory connected accounts and sending, with the server rules the
/// screens rely on: a send needs a connected account and an open window
/// (templates excepted), a queued send can be cancelled, an unknown one can
/// be marked sent or sent again. Sent messages are appended to the
/// conversations fake. Records every call (tokens are recorded as `***`).
class FakeChannelsRepository implements ChannelsRepository {
  FakeChannelsRepository({
    this.conversations,
    List<Map<String, dynamic>>? providers,
    List<Map<String, dynamic>>? connections,
    this.templateItems = const [],
  }) : providerRows = providers ?? defaultProviders(),
       connectionRows = connections ?? [];

  final FakeConversationsRepository? conversations;
  final List<Map<String, dynamic>> providerRows;
  final List<Map<String, dynamic>> connectionRows;
  final List<Map<String, dynamic>> templateItems;
  final calls = <String>[];

  /// Texts the seller authorized, in order.
  final sentTexts = <String>[];
  var _seq = 0;

  /// The next call fails with this error (then it is cleared).
  ApiException? failNext;

  /// The provider's answer to a bot token (null: accepted).
  ApiException? refuseToken;

  /// Delivery state given to the next authorized send after dispatch.
  String dispatchOutcome = 'sent';

  static List<Map<String, dynamic>> defaultProviders() => [
    {
      'provider': 'telegram',
      'name': 'Telegram',
      'status': 'pilot',
      'connect_method': 'bot_token',
      'can_connect': true,
      'ui_state': 'disconnected',
    },
    {
      'provider': 'instagram',
      'name': 'Instagram',
      'status': 'pilot',
      'connect_method': 'meta_login',
      'can_connect': true,
      'ui_state': 'disconnected',
    },
    {
      'provider': 'tiktok',
      'name': 'TikTok',
      'status': 'planned',
      'connect_method': 'tiktok_oauth',
      'can_connect': false,
      'ui_state': 'unavailable',
    },
  ];

  static Map<String, dynamic> connectionJson({
    String id = 'k1',
    String provider = 'telegram',
    String name = 'Shop bot',
    String uiState = 'connected',
  }) => {
    'id': id,
    'provider': provider,
    'provider_name': provider[0].toUpperCase() + provider.substring(1),
    'display_name': name,
    'state': uiState == 'error' ? 'needs_attention' : 'connected',
    'ui_state': uiState,
    'can_send': uiState == 'connected',
    'is_test': false,
  };

  static Map<String, dynamic> channelJson({
    String provider = 'whatsapp',
    String providerName = 'WhatsApp',
    String uiState = 'connected',
    bool windowOpen = true,
    bool templates = false,
  }) => {
    'connection_id': 'k1',
    'provider': provider,
    'provider_name': providerName,
    'account_name': 'Shop',
    'ui_state': uiState,
    'can_send': uiState == 'connected',
    'window_open': windowOpen,
    'templates': templates,
    'contact_blocked': false,
  };

  void _maybeFail(String call) {
    calls.add(call);
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  @override
  Future<List<ChannelProvider>> providers(String storeId) async {
    _maybeFail('providers');
    return [for (final p in providerRows) ChannelProvider.fromJson(p)];
  }

  @override
  Future<List<ChannelConnection>> connections(String storeId) async {
    _maybeFail('connections');
    return [for (final c in connectionRows) ChannelConnection.fromJson(c)];
  }

  @override
  Future<String> beginConnect(String storeId, String provider) async {
    _maybeFail('begin:$provider');
    return 'nonce-${++_seq}';
  }

  @override
  Future<void> connectBot(String provider, String nonce, String token) async {
    _maybeFail('connectBot:$provider:$nonce:***');
    if (refuseToken case final e?) throw e;
    connectionRows.add(connectionJson(id: 'k-${++_seq}', provider: provider));
  }

  @override
  Future<Uri> authorizationUrl(String provider, String nonce) async {
    _maybeFail('authorize:$provider:$nonce');
    return Uri.parse('https://provider.example/authorize?state=$nonce');
  }

  @override
  Future<void> disconnect(String storeId, String connectionId) async {
    _maybeFail('disconnect:$connectionId');
    connectionRows.removeWhere((c) => c['id'] == connectionId);
  }

  Map<String, dynamic> _append(
    String conversationId,
    String text,
    String kind,
  ) {
    final c = conversations!.raw(conversationId);
    final channel = c['channel'] as Map<String, dynamic>?;
    if (channel == null || channel['can_send'] != true) {
      throw const ApiException(ApiErrorCode.channelUnavailable);
    }
    final id = 'send-${++_seq}';
    final message = FakeConversationsRepository.messageJson(
      'mo-$_seq',
      text,
      inbound: false,
      origin: 'seller_sent',
      state: 'live',
      delivery: 'queued',
      send: {
        'id': id,
        'state': 'queued',
        'kind': kind,
        'attempts': 0,
        'can_cancel': true,
        'can_resolve': false,
      },
    );
    c['messages'] = [...c['messages'] as List, message];
    sentTexts.add(text);
    return message;
  }

  Map<String, dynamic>? _messageOfSend(String sendId) {
    for (final c in [
      for (final id in _conversationIds) conversations!.raw(id),
    ]) {
      for (final m in (c['messages'] as List).cast<Map<String, dynamic>>()) {
        if ((m['send'] as Map?)?['id'] == sendId) return m;
      }
    }
    return null;
  }

  final _conversationIds = <String>{};

  @override
  Future<SendReceipt> send(
    String storeId,
    String conversationId,
    String text, {
    String? suggestionId,
    String kind = 'reply',
    String? orderId,
    required String idempotencyKey,
  }) async {
    _maybeFail('send:$kind:${suggestionId ?? '-'}');
    final c = conversations!.raw(conversationId);
    if ((c['channel'] as Map?)?['window_open'] == false) {
      throw const ApiException(ApiErrorCode.replyWindowClosed);
    }
    _conversationIds.add(conversationId);
    final m = _append(conversationId, text, kind);
    return SendReceipt(
      sendRequestId: (m['send'] as Map)['id'] as String,
      state: 'queued',
    );
  }

  @override
  Future<void> dispatch(String sendRequestId) async {
    _maybeFail('dispatch:$sendRequestId');
    final m = _messageOfSend(sendRequestId);
    if (m == null) return;
    final send = m['send'] as Map<String, dynamic>;
    final outcome = dispatchOutcome;
    m['delivery_state'] = outcome;
    send['state'] = outcome;
    send['can_cancel'] = false;
    send['can_resolve'] = outcome == 'unknown';
    if (outcome == 'failed') send['error_code'] = 'window_closed';
  }

  @override
  Future<TemplateList> templates(String storeId, String conversationId) async {
    _maybeFail('templates');
    final c = conversations!.raw(conversationId);
    return TemplateList.fromJson({
      'window_open': (c['channel'] as Map?)?['window_open'] != false,
      'items': templateItems,
    });
  }

  @override
  Future<SendReceipt> sendTemplate(
    String storeId,
    String conversationId,
    String templateId,
    List<String> params, {
    required String idempotencyKey,
  }) async {
    _maybeFail('sendTemplate:$templateId:${params.join('|')}');
    final t = MessageTemplate.fromJson(
      templateItems.firstWhere((t) => t['id'] == templateId),
    );
    if (params.length != t.paramCount ||
        !params.every(MessageTemplate.paramOk)) {
      throw const ApiException(
        ApiErrorCode.validationFailed,
        fields: {'params': 'invalid'},
      );
    }
    _conversationIds.add(conversationId);
    final m = _append(conversationId, t.render(params), 'template');
    return SendReceipt(
      sendRequestId: (m['send'] as Map)['id'] as String,
      state: 'queued',
    );
  }

  @override
  Future<void> cancelSend(String storeId, String sendRequestId) async {
    _maybeFail('cancel:$sendRequestId');
    final m = _messageOfSend(sendRequestId)!;
    final send = m['send'] as Map<String, dynamic>;
    if (send['state'] != 'queued') {
      throw const ApiException(ApiErrorCode.sendStateChanged);
    }
    m['delivery_state'] = 'cancelled';
    send['state'] = 'cancelled';
    send['can_cancel'] = false;
  }

  @override
  Future<String?> resolveUnknown(
    String storeId,
    String sendRequestId,
    String resolution, {
    required String idempotencyKey,
  }) async {
    _maybeFail('resolve:$sendRequestId:$resolution');
    final m = _messageOfSend(sendRequestId)!;
    final send = m['send'] as Map<String, dynamic>;
    send['can_resolve'] = false;
    send['resolution'] = resolution;
    if (resolution == 'mark_sent') {
      m['delivery_state'] = 'sent';
      send['state'] = 'sent';
      return null;
    }
    final conversationId = _conversationIds.firstWhere(
      (id) => (conversations!.raw(id)['messages'] as List).contains(m),
    );
    final again = _append(
      conversationId,
      m['body'] as String,
      send['kind'] as String,
    );
    return (again['send'] as Map)['id'] as String;
  }

  @override
  Future<String> confirmationText(
    String storeId,
    String orderId,
    String lang,
  ) async {
    _maybeFail('confirmation:$orderId:$lang');
    return 'Order #1001 is confirmed: 75,000 IQD.';
  }
}
