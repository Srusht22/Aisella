import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../catalog/application/catalog_providers.dart'
    show currentStoreIdProvider;
import '../../orders/application/order_providers.dart';
import '../../store/application/workspace_controller.dart'
    show noAutomaticRetry;
import '../data/conversations_repository.dart';
import '../domain/conversation.dart';

export '../data/conversations_repository.dart'
    show conversationsRepositoryProvider;

String _requireStore(Ref ref) {
  final id = ref.read(currentStoreIdProvider);
  if (id == null) throw const ApiException(ApiErrorCode.notFound);
  return id;
}

// ---------------------------------------------------------------------------
// Inbox list (US-022)
// ---------------------------------------------------------------------------

final inboxFilterProvider =
    NotifierProvider<InboxFilterController, InboxFilter>(
      InboxFilterController.new,
    );

class InboxFilterController extends Notifier<InboxFilter> {
  @override
  InboxFilter build() {
    ref.watch(currentStoreIdProvider);
    return InboxFilter.open;
  }

  void set(InboxFilter filter) => state = filter;
}

const inboxPageSize = 30;

@immutable
class InboxState {
  const InboxState({
    required this.filter,
    required this.page,
    this.loadingMore = false,
    this.moreFailed = false,
  });

  final InboxFilter filter;
  final ConversationPage page;
  final bool loadingMore;
  final bool moreFailed;

  InboxState copyWith({
    ConversationPage? page,
    bool? loadingMore,
    bool? moreFailed,
  }) => InboxState(
    filter: filter,
    page: page ?? this.page,
    loadingMore: loadingMore ?? this.loadingMore,
    moreFailed: moreFailed ?? this.moreFailed,
  );
}

final inboxProvider = AsyncNotifierProvider<InboxController, InboxState>(
  InboxController.new,
  retry: noAutomaticRetry,
);

class InboxController extends AsyncNotifier<InboxState> {
  @override
  Future<InboxState> build() async {
    final storeId = ref.watch(currentStoreIdProvider);
    final filter = ref.watch(inboxFilterProvider);
    if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
    final page = await ref
        .read(conversationsRepositoryProvider)
        .list(storeId, filter, limit: inboxPageSize);
    return InboxState(filter: filter, page: page);
  }

  Future<void> loadMore() async {
    final current = state.value;
    final storeId = ref.read(currentStoreIdProvider);
    if (current == null ||
        storeId == null ||
        !current.page.hasMore ||
        current.loadingMore) {
      return;
    }
    state = AsyncData(current.copyWith(loadingMore: true, moreFailed: false));
    try {
      final next = await ref
          .read(conversationsRepositoryProvider)
          .list(storeId, current.filter, offset: current.page.items.length);
      state = AsyncData(
        current.copyWith(
          loadingMore: false,
          page: ConversationPage(
            items: [...current.page.items, ...next.items],
            total: next.total,
            hasMore: next.hasMore,
            needsYou: next.needsYou,
            needsReply: next.needsReply,
            waiting: next.waiting,
          ),
        ),
      );
    } on ApiException {
      state = AsyncData(current.copyWith(loadingMore: false, moreFailed: true));
    }
  }
}

/// The conversation shown in the tablet list–detail layout.
final selectedConversationProvider =
    NotifierProvider<SelectedConversation, String?>(SelectedConversation.new);

class SelectedConversation extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(currentStoreIdProvider);
    return null;
  }

  void select(String? id) => state = id;
}

final conversationProvider = FutureProvider.autoDispose
    .family<Conversation, String>((ref, conversationId) {
      final storeId = ref.watch(currentStoreIdProvider);
      if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
      return ref
          .read(conversationsRepositoryProvider)
          .get(storeId, conversationId);
    }, retry: noAutomaticRetry);

final aiSettingsProvider = FutureProvider.autoDispose<AiSettings>((ref) {
  final storeId = ref.watch(currentStoreIdProvider);
  if (storeId == null) throw const ApiException(ApiErrorCode.notFound);
  return ref.read(conversationsRepositoryProvider).aiSettings(storeId);
}, retry: noAutomaticRetry);

// ---------------------------------------------------------------------------
// Actions. Reads refresh after the server answered. Retries of a lost answer
// reuse the same idempotency key (one intent, one effect).
// ---------------------------------------------------------------------------

final inboxActionsProvider = Provider<InboxActions>(InboxActions.new);

class InboxActions {
  InboxActions(this._ref);

  final Ref _ref;

  ConversationsRepository get _repo =>
      _ref.read(conversationsRepositoryProvider);

  Future<T> _withReplay<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException catch (e) {
      if (!e.outcomeUnknown) rethrow;
      return run();
    }
  }

  void _refresh([String? conversationId]) {
    _ref.invalidate(inboxProvider);
    if (conversationId != null) {
      _ref.invalidate(conversationProvider(conversationId));
    }
  }

  Future<String> create({
    required ConversationSource source,
    String? customerLabel,
    required List<ImportedMessage> messages,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    final id = await _withReplay(
      () => _repo.create(
        storeId,
        source: source,
        customerLabel: customerLabel,
        messages: messages,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(id);
    return id;
  }

  Future<void> importMessages(
    String conversationId,
    List<ImportedMessage> messages, {
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    await _withReplay(
      () => _repo.importMessages(
        storeId,
        conversationId,
        messages,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(conversationId);
  }

  Future<void> recordSellerReply(
    String conversationId,
    String body, {
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    await _withReplay(
      () => _repo.recordSellerReply(
        storeId,
        conversationId,
        body,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(conversationId);
  }

  Future<void> update(
    Conversation conversation, {
    ConversationStatus? status,
    bool? aiPaused,
  }) async {
    final storeId = _requireStore(_ref);
    await _repo.update(
      storeId,
      conversation.id,
      expectedVersion: conversation.summary.version,
      status: status,
      aiPaused: aiPaused,
    );
    _refresh(conversation.id);
  }

  /// Asks the server-side assistant. A lost answer is asked again with the
  /// same key: the server replays the run instead of calling the model again.
  Future<AssistOutcome> assist(
    String conversationId, {
    bool draft = false,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    try {
      return await _withReplay(
        () => _repo.requestAssist(
          storeId,
          conversationId,
          draft: draft,
          idempotencyKey: idempotencyKey,
        ),
      );
    } finally {
      _refresh(conversationId);
      // A run may have created or updated a draft.
      _ref.invalidate(orderListProvider);
      _ref.invalidate(orderCountsProvider);
    }
  }

  Future<void> copySuggestion(
    String conversationId,
    Suggestion suggestion, {
    String? editedText,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    await _withReplay(
      () => _repo.copySuggestion(
        storeId,
        suggestion.id,
        editedText: editedText,
        idempotencyKey: idempotencyKey,
      ),
    );
    _refresh(conversationId);
  }

  Future<void> markSent(String conversationId, String messageId) async {
    await _repo.markSent(_requireStore(_ref), messageId);
    _refresh(conversationId);
  }

  Future<void> dismiss(String conversationId, Suggestion suggestion) async {
    await _repo.dismissSuggestion(_requireStore(_ref), suggestion.id);
    _refresh(conversationId);
  }

  Future<void> delete(String conversationId) async {
    await _repo.deleteConversation(_requireStore(_ref), conversationId);
    _ref.invalidate(inboxProvider);
    if (_ref.read(selectedConversationProvider) == conversationId) {
      _ref.read(selectedConversationProvider.notifier).select(null);
    }
  }

  Future<void> setAiEnabled(bool enabled) async {
    await _repo.setAiEnabled(_requireStore(_ref), enabled);
    _ref.invalidate(aiSettingsProvider);
  }

  Future<void> upsertPolicy({
    StorePolicy? existing,
    required PolicyTopic topic,
    required String body,
    required String idempotencyKey,
  }) async {
    final storeId = _requireStore(_ref);
    await _withReplay(
      () => _repo.upsertPolicy(
        storeId,
        policyId: existing?.id,
        expectedVersion: existing?.version,
        topic: topic,
        body: body,
        active: existing?.active ?? true,
        idempotencyKey: idempotencyKey,
      ),
    );
    _ref.invalidate(aiSettingsProvider);
  }

  Future<void> deletePolicy(StorePolicy policy) async {
    await _repo.deletePolicy(
      _requireStore(_ref),
      policy.id,
      expectedVersion: policy.version,
    );
    _ref.invalidate(aiSettingsProvider);
  }
}
