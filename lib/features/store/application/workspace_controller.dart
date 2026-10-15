import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/auth_status.dart';
import '../data/store_repository.dart';
import '../domain/store.dart';

final storeRepositoryProvider = Provider<StoreRepository>(
  (ref) => SupabaseStoreRepository(ref.watch(supabaseClientProvider)),
);

/// Id of the signed-in user, or null. Everything user-specific is keyed on
/// this, so signing out (or a different seller signing in) discards it.
final currentUserIdProvider = Provider<String?>((ref) {
  final status = ref.watch(authControllerProvider);
  return status is SignedIn ? status.user.id : null;
});

/// The signed-in seller's account and store, from the server
/// (api.get_my_context). Null when nobody is signed in.
final workspaceProvider =
    AsyncNotifierProvider<WorkspaceController, AccountContext?>(
      WorkspaceController.new,
      retry: noAutomaticRetry,
    );

/// Riverpod 3 retries failed providers automatically. Server reads here must
/// not: a rejected session (401) has to sign the seller out at once, and other
/// failures are shown with an explicit Retry (P-ERR-LOAD).
Duration? noAutomaticRetry(int retryCount, Object error) => null;

class WorkspaceController extends AsyncNotifier<AccountContext?> {
  StoreRepository get _repo => ref.read(storeRepositoryProvider);

  @override
  Future<AccountContext?> build() async {
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return null;
    return _guardAuth(_repo.loadContext);
  }

  /// Reloads from the server, showing the loading state (Retry on the
  /// workspace error screen).
  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _guardAuth(_repo.loadContext));
  }

  /// Re-reads the server state while keeping the current data on screen
  /// (after a version conflict in a settings screen). Navigation is not
  /// disturbed; on failure the current data stays and the error is rethrown.
  Future<void> refresh() async {
    final ctx = await _guardAuth(_repo.loadContext);
    state = AsyncData(ctx);
  }

  /// AU-07. Safe to retry with the same key. When the outcome is unknown
  /// (timeout) or the server says a store already exists, the server state is
  /// read back first, so a store created by an earlier attempt is adopted
  /// instead of reported as a failure or duplicated.
  Future<Store> createStore(
    StoreDraft draft, {
    required String idempotencyKey,
  }) async {
    try {
      final store = await _guardAuth(
        () => _repo.createStore(draft, idempotencyKey: idempotencyKey),
      );
      _setStore(store);
      return store;
    } on ApiException catch (e) {
      if (e.outcomeUnknown || e.code == ApiErrorCode.limitExceeded) {
        final existing = await _reconcile();
        if (existing != null) return existing;
      }
      rethrow;
    }
  }

  Future<Store> updateStore({
    required Map<String, Object> changes,
    required String idempotencyKey,
  }) async {
    final store = _requireStore();
    final updated = await _guardAuth(
      () => _repo.updateStore(
        store.id,
        expectedVersion: store.version,
        changes: changes,
        idempotencyKey: idempotencyKey,
      ),
    );
    _setStore(updated);
    return updated;
  }

  Future<Store> advanceOnboarding(OnboardingStep step) async {
    final store = _requireStore();
    final updated = await _guardAuth(
      () => _repo.advanceOnboarding(store.id, step),
    );
    _setStore(updated);
    return updated;
  }

  /// ST-08: re-authentication happens first (in the auth controller); then
  /// the request, then the server state is read back so the router shows the
  /// closed-account screen. Nothing is reported as deleted unless the server
  /// accepted the request.
  Future<DateTime> requestAccountDeletion(String confirmStoreName) async {
    final executeAfter = await _guardAuth(
      () => _repo.requestAccountDeletion(confirmStoreName: confirmStoreName),
    );
    await refresh();
    return executeAfter;
  }

  /// Applies a store returned by a zone operation's caller, or after reload.
  void _setStore(Store store) {
    final ctx = state.value;
    if (ctx != null) state = AsyncData(ctx.withStore(store));
  }

  Store _requireStore() {
    final store = state.value?.store;
    if (store == null) throw const ApiException(ApiErrorCode.notFound);
    return store;
  }

  Future<Store?> _reconcile() async {
    try {
      final ctx = await _guardAuth(_repo.loadContext);
      if (ctx.store != null) {
        state = AsyncData(ctx);
        return ctx.store;
      }
    } on ApiException {
      // Still unknown: the caller reports the original failure.
    }
    return null;
  }

  /// A rejected session (401) signs the seller out locally; the router then
  /// shows sign-in instead of an error.
  Future<T> _guardAuth<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ApiException catch (e) {
      if (e.code == ApiErrorCode.unauthenticated) {
        await ref.read(authControllerProvider.notifier).sessionRejected();
      }
      rethrow;
    }
  }
}

/// Active delivery zones of the current store, in display order.
final zonesProvider = FutureProvider.autoDispose<List<DeliveryZone>>(
  retry: noAutomaticRetry,
  (ref) async {
    final storeId = ref.watch(
      workspaceProvider.select((w) => w.value?.store?.id),
    );
    if (storeId == null) return const [];
    return ref.read(storeRepositoryProvider).listZones(storeId);
  },
);

/// Zone mutations; each refreshes [zonesProvider] after it succeeds.
final zoneActionsProvider = Provider<ZoneActions>(ZoneActions.new);

class ZoneActions {
  ZoneActions(this._ref);

  final Ref _ref;

  String get _storeId {
    final id = _ref.read(workspaceProvider).value?.store?.id;
    if (id == null) throw const ApiException(ApiErrorCode.notFound);
    return id;
  }

  Future<DeliveryZone> save({
    DeliveryZone? existing,
    required String name,
    required int fee,
    String? timeText,
    required String idempotencyKey,
  }) async {
    final zone = await _ref
        .read(storeRepositoryProvider)
        .upsertZone(
          _storeId,
          zoneId: existing?.id,
          expectedVersion: existing?.version,
          name: name,
          fee: fee,
          timeText: timeText,
          idempotencyKey: idempotencyKey,
        );
    _ref.invalidate(zonesProvider);
    return zone;
  }

  Future<void> remove(DeliveryZone zone) async {
    await _ref
        .read(storeRepositoryProvider)
        .deactivateZone(
          _storeId,
          zoneId: zone.id,
          expectedVersion: zone.version,
        );
    _ref.invalidate(zonesProvider);
  }
}
