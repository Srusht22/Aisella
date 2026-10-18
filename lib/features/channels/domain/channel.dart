import 'package:flutter/foundation.dart';

/// How a messaging account is shown to the seller (Phase 9): one of five
/// states, decided by the server (`app.connection_ui_state`).
enum ConnectionUiState {
  disconnected,
  awaitingAuthorization,
  connected,
  error,

  /// Connected, but the provider cannot send yet (not released, suspended or
  /// its API behaviour not verified).
  unavailable;

  static ConnectionUiState parse(Object? v) => switch (v) {
    'awaiting_authorization' => ConnectionUiState.awaitingAuthorization,
    'connected' => ConnectionUiState.connected,
    'error' => ConnectionUiState.error,
    'unavailable' => ConnectionUiState.unavailable,
    _ => ConnectionUiState.disconnected,
  };
}

/// How an account is connected: a bot token pasted by the seller (Telegram,
/// Viber), or the provider's own authorization page (Meta, TikTok).
enum ConnectMethod {
  botToken,
  metaLogin,
  whatsappSignup,
  tiktokOauth;

  static ConnectMethod? parse(Object? v) => switch (v) {
    'bot_token' => ConnectMethod.botToken,
    'meta_login' => ConnectMethod.metaLogin,
    'whatsapp_signup' => ConnectMethod.whatsappSignup,
    'tiktok_oauth' => ConnectMethod.tiktokOauth,
    _ => null,
  };

  /// Opens a provider page in the browser (not a token form).
  bool get usesBrowser => this != ConnectMethod.botToken;
}

/// A messaging provider the store can connect (`api.list_channel_providers`).
@immutable
class ChannelProvider {
  const ChannelProvider({
    required this.id,
    required this.name,
    required this.uiState,
    required this.canConnect,
    this.method,
  });

  factory ChannelProvider.fromJson(Map<String, dynamic> j) => ChannelProvider(
    id: j['provider'] as String,
    name: j['name'] as String? ?? j['provider'] as String,
    uiState: ConnectionUiState.parse(j['ui_state']),
    canConnect: j['can_connect'] == true,
    method: ConnectMethod.parse(j['connect_method']),
  );

  final String id;
  final String name;
  final ConnectionUiState uiState;

  /// Released for sellers and has a connect method.
  final bool canConnect;
  final ConnectMethod? method;
}

/// A connected account (`api.list_connections`). No token, phone number or
/// provider id reaches the app.
@immutable
class ChannelConnection {
  const ChannelConnection({
    required this.id,
    required this.provider,
    required this.providerName,
    required this.uiState,
    required this.canSend,
    this.displayName,
    this.username,
    this.attentionReason,
    this.isTest = false,
    this.lastEventAt,
  });

  factory ChannelConnection.fromJson(Map<String, dynamic> j) =>
      ChannelConnection(
        id: j['id'] as String,
        provider: j['provider'] as String,
        providerName: j['provider_name'] as String? ?? j['provider'] as String,
        uiState: ConnectionUiState.parse(j['ui_state']),
        canSend: j['can_send'] == true,
        displayName: j['display_name'] as String?,
        username: j['username'] as String?,
        attentionReason: j['attention_reason'] as String?,
        isTest: j['is_test'] == true,
        lastEventAt: j['last_event_at'] == null
            ? null
            : DateTime.parse(j['last_event_at'] as String).toLocal(),
      );

  final String id;
  final String provider;
  final String providerName;
  final ConnectionUiState uiState;
  final bool canSend;
  final String? displayName;
  final String? username;
  final String? attentionReason;
  final bool isTest;
  final DateTime? lastEventAt;
}

/// The channel of a live conversation (part of the conversation summary).
@immutable
class ConversationChannel {
  const ConversationChannel({
    required this.connectionId,
    required this.provider,
    required this.providerName,
    required this.uiState,
    required this.canSend,
    required this.windowOpen,
    this.accountName,
    this.windowExpiresAt,
    this.templates = false,
    this.contactBlocked = false,
  });

  factory ConversationChannel.fromJson(Map<String, dynamic> j) =>
      ConversationChannel(
        connectionId: j['connection_id'] as String,
        provider: j['provider'] as String,
        providerName: j['provider_name'] as String? ?? j['provider'] as String,
        accountName: j['account_name'] as String?,
        uiState: ConnectionUiState.parse(j['ui_state']),
        canSend: j['can_send'] == true,
        windowOpen: j['window_open'] != false,
        windowExpiresAt: j['window_expires_at'] == null
            ? null
            : DateTime.parse(j['window_expires_at'] as String).toLocal(),
        templates: j['templates'] == true,
        contactBlocked: j['contact_blocked'] == true,
      );

  final String connectionId;
  final String provider;
  final String providerName;
  final String? accountName;
  final ConnectionUiState uiState;
  final bool canSend;

  /// Inside the customer-service window (always true for providers without
  /// one).
  final bool windowOpen;
  final DateTime? windowExpiresAt;

  /// The provider sends approved templates outside the window (WhatsApp).
  final bool templates;
  final bool contactBlocked;
}

/// Delivery of a message sent through a channel, as far as it is known.
enum DeliveryState {
  queued,
  sending,
  sent,
  delivered,
  read,
  failed,

  /// The provider may or may not have received it: never resent
  /// automatically; the seller decides.
  unknown,
  cancelled;

  static DeliveryState? parse(Object? v) =>
      values.where((s) => s.name == v).firstOrNull;
}

/// The send request behind a message sent through a channel.
@immutable
class SendInfo {
  const SendInfo({
    required this.id,
    required this.state,
    required this.kind,
    this.errorCode,
    this.attempts = 0,
    this.canCancel = false,
    this.canResolve = false,
  });

  factory SendInfo.fromJson(Map<String, dynamic> j) => SendInfo(
    id: j['id'] as String,
    state: j['state'] as String? ?? 'queued',
    kind: j['kind'] as String? ?? 'reply',
    errorCode: j['error_code'] as String?,
    attempts: (j['attempts'] as num?)?.toInt() ?? 0,
    canCancel: j['can_cancel'] == true,
    canResolve: j['can_resolve'] == true,
  );

  final String id;

  /// queued, sending, sent, failed, unknown, cancelled.
  final String state;

  /// reply, order_confirmation or template.
  final String kind;
  final String? errorCode;
  final int attempts;
  final bool canCancel;
  final bool canResolve;
}

/// What the server returns after authorizing a send.
@immutable
class SendReceipt {
  const SendReceipt({required this.sendRequestId, required this.state});

  factory SendReceipt.fromJson(Map<String, dynamic> j) => SendReceipt(
    sendRequestId: j['send_request_id'] as String,
    state: j['state'] as String? ?? 'queued',
  );

  final String sendRequestId;
  final String state;
}

/// An approved WhatsApp template the seller may send outside the window.
@immutable
class MessageTemplate {
  const MessageTemplate({
    required this.id,
    required this.name,
    required this.language,
    required this.body,
    required this.paramCount,
  });

  factory MessageTemplate.fromJson(Map<String, dynamic> j) => MessageTemplate(
    id: j['id'] as String,
    name: j['name'] as String,
    language: j['language'] as String? ?? '',
    body: j['body_text'] as String? ?? '',
    paramCount: (j['param_count'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String name;
  final String language;
  final String body;
  final int paramCount;

  /// The same rendering as the server's (`app.render_template`): every
  /// `{{n}}` replaced by parameter n. Shown to the seller before sending;
  /// the server renders the text that is actually authorized.
  String render(List<String> params) {
    var out = body;
    for (var i = 0; i < params.length; i++) {
      out = out.split('{{${i + 1}}}').join(params[i]);
    }
    return out;
  }

  /// The server's parameter rule: 1–300 characters, no line breaks or tabs,
  /// no four spaces in a row, no `{{`.
  static bool paramOk(String p) =>
      p.isNotEmpty &&
      p.length <= 300 &&
      !p.contains(RegExp(r'[\n\r\t]')) &&
      !p.contains('    ') &&
      !p.contains('{{');
}

@immutable
class TemplateList {
  const TemplateList({required this.windowOpen, required this.items});

  factory TemplateList.fromJson(Map<String, dynamic> j) => TemplateList(
    windowOpen: j['window_open'] == true,
    items: [
      for (final t in j['items'] as List? ?? const [])
        MessageTemplate.fromJson((t as Map).cast<String, dynamic>()),
    ],
  );

  final bool windowOpen;
  final List<MessageTemplate> items;
}
