import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../../core/backend/api.dart';
import '../../catalog/application/catalog_providers.dart'
    show currentStoreIdProvider;
import '../../inbox/application/inbox_providers.dart'
    show conversationProvider, inboxProvider;
import '../../store/application/workspace_controller.dart'
    show noAutomaticRetry;
import '../data/channels_repository.dart';
import '../domain/channel.dart';

export '../data/channels_repository.dart' show channelsRepositoryProvider;

String _requireStore(Ref ref) {
  final id = ref.read(currentStoreIdProvider);
  if (id == null) throw const ApiException(ApiErrorCode.notFound);
  return id;
}

/// The providers the store can connect, with the state of each.
final channelProvidersProvider =
    FutureProvider.autoDispose<List<ChannelProvider>>((ref) {
      final storeId = ref.watch(currentStoreIdProvider);
      if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
      return ref.read(channelsRepositoryProvider).providers(storeId);
    }, retry: noAutomaticRetry);

final connectionsProvider = FutureProvider.autoDispose<List<ChannelConnection>>(
  (ref) {
    final storeId = ref.watch(currentStoreIdProvider);
    if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
    return ref.read(channelsRepositoryProvider).connections(storeId);
  },
  retry: noAutomaticRetry,
);

/// Templates of a live conversation's account, and whether its window is
/// open.
final templatesProvider = FutureProvider.autoDispose
    .family<TemplateList, String>((ref, conversationId) {
      final storeId = ref.watch(currentStoreIdProvider);
      if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
      return ref
          .read(channelsRepositoryProvider)
          .templates(storeId, conversationId);
    }, retry: noAutomaticRetry);

/// Opens a provider page outside the app (the seller authorizes there).
/// Replaced in tests.
final urlOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launcher.launchUrl(
        uri,
        mode: launcher.LaunchMode.externalApplication,
      ),
);

final channelActionsProvider = Provider<ChannelActions>(ChannelActions.new);

/// Connecting accounts and sending through them. Sending always needs the
/// seller's explicit confirmation of the exact text on screen: these actions
/// are only called from that confirmation (never by the AI).
class ChannelActions {
  ChannelActions(this._ref);

  final Ref _ref;

  ChannelsRepository get _repo => _ref.read(channelsRepositoryProvider);

  void _refreshAccounts() {
    _ref.invalidate(connectionsProvider);
    _ref.invalidate(channelProvidersProvider);
  }

  void _refreshConversation(String conversationId) {
    _ref.invalidate(conversationProvider(conversationId));
    _ref.invalidate(templatesProvider(conversationId));
    _ref.invalidate(inboxProvider);
  }

  /// A retry after a lost answer reuses the same key: one intent, one send.
  Future<T> _withReplay<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException catch (e) {
      if (!e.outcomeUnknown) rethrow;
      return run();
    }
  }

  Future<void> connectBot(String provider, String token) async {
    final storeId = _requireStore(_ref);
    final nonce = await _repo.beginConnect(storeId, provider);
    try {
      await _repo.connectBot(provider, nonce, token);
    } finally {
      _refreshAccounts();
    }
  }

  /// Starts the provider's authorization page. Returns false if the page
  /// could not be opened. The account appears once the provider redirects
  /// back to Aisellia (the list then shows it).
  Future<bool> startAuthorization(String provider) async {
    final storeId = _requireStore(_ref);
    final nonce = await _repo.beginConnect(storeId, provider);
    final url = await _repo.authorizationUrl(provider, nonce);
    final opened = await _ref.read(urlOpenerProvider)(url);
    _refreshAccounts();
    return opened;
  }

  void refreshAccounts() => _refreshAccounts();

  Future<void> disconnect(ChannelConnection connection) async {
    await _repo.disconnect(_requireStore(_ref), connection.id);
    _refreshAccounts();
  }

  Future<void> _submit(String conversationId, SendReceipt receipt) async {
    // Immediate submission; if this fails the background worker sends it.
    try {
      await _repo.dispatch(receipt.sendRequestId);
    } on ApiException {
      // Shown through the message's delivery state.
    }
    _refreshConversation(conversationId);
  }

  Future<SendReceipt> send(
    String conversationId,
    String text, {
    String? suggestionId,
    String kind = 'reply',
    String? orderId,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final SendReceipt receipt;
    try {
      receipt = await _withReplay(
        () => _repo.send(
          storeId,
          conversationId,
          text,
          suggestionId: suggestionId,
          kind: kind,
          orderId: orderId,
          idempotencyKey: idempotencyKey,
        ),
      );
    } on ApiException {
      _refreshConversation(conversationId);
      rethrow;
    }
    await _submit(conversationId, receipt);
    return receipt;
  }

  Future<SendReceipt> sendTemplate(
    String conversationId,
    MessageTemplate template,
    List<String> params, {
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final receipt = await _withReplay(
      () => _repo.sendTemplate(
        storeId,
        conversationId,
        template.id,
        params,
        idempotencyKey: idempotencyKey,
      ),
    );
    await _submit(conversationId, receipt);
    return receipt;
  }

  Future<void> cancel(String conversationId, SendInfo send) async {
    try {
      await _repo.cancelSend(_requireStore(_ref), send.id);
    } finally {
      _refreshConversation(conversationId);
    }
  }

  /// The seller decides an unknown outcome: `mark_sent` or `send_again`.
  Future<void> resolveUnknown(
    String conversationId,
    SendInfo send,
    String resolution, {
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final String? resent;
    try {
      resent = await _withReplay(
        () => _repo.resolveUnknown(
          storeId,
          send.id,
          resolution,
          idempotencyKey: idempotencyKey,
        ),
      );
    } catch (_) {
      _refreshConversation(conversationId);
      rethrow;
    }
    if (resent != null) {
      await _submit(
        conversationId,
        SendReceipt(sendRequestId: resent, state: 'queued'),
      );
    } else {
      _refreshConversation(conversationId);
    }
  }

  Future<String> confirmationText(String orderId, String lang) =>
      _repo.confirmationText(_requireStore(_ref), orderId, lang);
}
