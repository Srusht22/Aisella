import 'dart:async';

import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/core/formatting/money.dart';
import 'package:aisellia/features/auth/data/auth_repository.dart';
import 'package:aisellia/features/auth/domain/auth_status.dart';
import 'package:aisellia/features/store/data/store_repository.dart';
import 'package:aisellia/features/store/domain/store.dart';

const testUser = AuthUser(
  id: '00000000-0000-4000-8000-000000000001',
  email: 'seller@example.test',
  emailVerified: true,
);

Store testStore({
  OnboardingStep step = OnboardingStep.done,
  int version = 1,
  bool cod = true,
  bool other = false,
  String name = 'Shilan Boutique',
}) => Store(
  id: '00000000-0000-4000-8000-0000000000aa',
  name: name,
  contactPhone: '+9647501234567',
  currency: Currency.iqd,
  replyLocale: 'ckb',
  businessCity: 'sulaymaniyah',
  codEnabled: cod,
  otherPaymentEnabled: other,
  onboardingStep: step,
  currencyLocked: false,
  version: version,
);

/// In-memory auth provider. Behaves like Supabase Auth from the app's point
/// of view: events on a stream, failures as [AuthError].
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({this.initialUser, this.signInDelay = Duration.zero});

  final AuthUser? initialUser;
  final Duration signInDelay;
  final _controller = StreamController<AuthEvent>.broadcast();

  /// Registered accounts: email → password. Verified unless listed in
  /// [unverified].
  final accounts = <String, String>{};
  final unverified = <String>{};

  /// When set, the next call fails with it.
  AuthFailure? failNext;

  final calls = <String>[];
  int signOutCalls = 0;

  @override
  Stream<AuthEvent> get events async* {
    yield AuthEvent(AuthEventKind.initial, initialUser);
    yield* _controller.stream;
  }

  void emit(AuthEventKind kind, [AuthUser? user]) =>
      _controller.add(AuthEvent(kind, user));

  void _maybeFail() {
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw AuthError(f);
    }
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String termsVersion,
  }) async {
    calls.add('signUp:$email:$termsVersion');
    _maybeFail();
    if (accounts.containsKey(email)) {
      throw const AuthError(AuthFailure.emailInUse);
    }
    accounts[email] = password;
    unverified.add(email);
    return SignUpOutcome.verificationRequired;
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    calls.add('signIn:$email');
    await Future<void>.delayed(signInDelay);
    _maybeFail();
    if (accounts[email] != password) {
      throw const AuthError(AuthFailure.invalidCredentials);
    }
    if (unverified.contains(email)) {
      throw const AuthError(AuthFailure.emailNotConfirmed);
    }
    emit(
      AuthEventKind.signedIn,
      AuthUser(id: testUser.id, email: email, emailVerified: true),
    );
  }

  @override
  Future<void> signOut({bool allDevices = false}) async {
    signOutCalls++;
    calls.add('signOut:${allDevices ? 'global' : 'local'}');
    emit(AuthEventKind.signedOut);
  }

  @override
  Future<void> clearLocalSession() async {
    calls.add('clearLocalSession');
    emit(AuthEventKind.signedOut);
  }

  @override
  Future<void> resendVerification(String email) async {
    calls.add('resend:$email');
    _maybeFail();
  }

  @override
  Future<void> requestPasswordReset(String email) async {
    calls.add('reset:$email');
    _maybeFail();
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    calls.add('updatePassword');
    _maybeFail();
  }

  @override
  Future<AuthUser?> reloadUser() async => initialUser;
}

/// In-memory store backend enforcing the same rules the tests rely on
/// (one store per user, idempotent replay, versions).
class FakeStoreRepository implements StoreRepository {
  FakeStoreRepository({
    this.store,
    List<DeliveryZone>? zones,
    this.loadDelay = Duration.zero,
  }) : zones = zones ?? [];

  /// Simulated latency of [loadContext].
  final Duration loadDelay;

  Store? store;
  final List<DeliveryZone> zones;
  final _replies = <String, Object>{};
  final calls = <String>[];

  /// When set, the next call fails with it (after optionally applying the
  /// change, to simulate a lost response).
  ApiException? failNext;
  bool applyThenFail = false;

  ApiException? _takeFailure() {
    final f = failNext;
    failNext = null;
    return f;
  }

  @override
  Future<AccountContext> loadContext() async {
    calls.add('loadContext');
    await Future<void>.delayed(loadDelay);
    final f = _takeFailure();
    if (f != null) throw f;
    return AccountContext(
      userId: testUser.id,
      email: testUser.email,
      emailVerified: true,
      deletionPending: deletionScheduledFor != null,
      deletionExecuteAfter: deletionScheduledFor,
      store: store,
    );
  }

  @override
  Future<Store> createStore(
    StoreDraft draft, {
    required String idempotencyKey,
  }) async {
    calls.add('createStore:$idempotencyKey');
    final replay = _replies[idempotencyKey];
    if (replay is Store) return replay;
    final f = _takeFailure();
    if (f != null && !applyThenFail) throw f;
    if (store != null) throw const ApiException(ApiErrorCode.limitExceeded);
    final created = Store(
      id: testStore().id,
      name: draft.name,
      contactPhone: draft.contactPhone,
      currency: draft.currency,
      replyLocale: draft.replyLocale,
      businessCity: draft.businessCity,
      codEnabled: true,
      otherPaymentEnabled: false,
      onboardingStep: OnboardingStep.zones,
      currencyLocked: false,
      version: 1,
    );
    store = created;
    _replies[idempotencyKey] = created;
    if (f != null) throw f; // applied, but the response was lost
    return created;
  }

  Store _bump(Store s, {OnboardingStep? step, Map<String, Object>? changes}) {
    final c = changes ?? const {};
    return Store(
      id: s.id,
      name: c['name'] as String? ?? s.name,
      contactPhone: c['contact_phone'] as String? ?? s.contactPhone,
      currency: c['currency'] == null
          ? s.currency
          : (c['currency'] == 'USD' ? Currency.usd : Currency.iqd),
      replyLocale: c['reply_locale'] as String? ?? s.replyLocale,
      businessCity: c['business_city'] as String? ?? s.businessCity,
      codEnabled: c['cod_enabled'] as bool? ?? s.codEnabled,
      otherPaymentEnabled:
          c['other_payment_enabled'] as bool? ?? s.otherPaymentEnabled,
      onboardingStep: step ?? s.onboardingStep,
      currencyLocked: s.currencyLocked,
      version: s.version + 1,
    );
  }

  @override
  Future<Store> updateStore(
    String storeId, {
    required int expectedVersion,
    required Map<String, Object> changes,
    required String idempotencyKey,
  }) async {
    calls.add('updateStore:$changes');
    final f = _takeFailure();
    if (f != null) throw f;
    final s = store;
    if (s == null || s.id != storeId) {
      throw const ApiException(ApiErrorCode.notFound);
    }
    if (s.version != expectedVersion) {
      throw ApiException(
        ApiErrorCode.conflictVersion,
        currentVersion: s.version,
      );
    }
    return store = _bump(s, changes: changes);
  }

  @override
  Future<Store> advanceOnboarding(String storeId, OnboardingStep step) async {
    calls.add('advance:${step.name}');
    final f = _takeFailure();
    if (f != null) throw f;
    final s = store!;
    if (step.index <= s.onboardingStep.index) return s;
    return store = _bump(s, step: step);
  }

  @override
  Future<List<DeliveryZone>> listZones(String storeId) async {
    calls.add('listZones');
    return List.of(zones);
  }

  @override
  Future<DeliveryZone> upsertZone(
    String storeId, {
    String? zoneId,
    int? expectedVersion,
    required String name,
    required int fee,
    String? timeText,
    required String idempotencyKey,
  }) async {
    calls.add('upsertZone:$name:$fee');
    final replay = _replies[idempotencyKey];
    if (replay is DeliveryZone) return replay;
    final f = _takeFailure();
    if (f != null) throw f;
    final index = zones.indexWhere((z) => z.id == zoneId);
    final zone = DeliveryZone(
      id: zoneId ?? 'zone-${zones.length + 1}',
      name: name,
      fee: fee,
      timeText: timeText,
      version: index < 0 ? 1 : zones[index].version + 1,
    );
    if (index < 0) {
      zones.add(zone);
    } else {
      zones[index] = zone;
    }
    _replies[idempotencyKey] = zone;
    return zone;
  }

  @override
  Future<void> deactivateZone(
    String storeId, {
    required String zoneId,
    required int expectedVersion,
  }) async {
    calls.add('deactivateZone:$zoneId');
    zones.removeWhere((z) => z.id == zoneId);
  }

  /// Set to the confirmation the fake expects (the store name); null rejects.
  DateTime? deletionScheduledFor;

  @override
  Future<DateTime> requestAccountDeletion({
    required String confirmStoreName,
  }) async {
    calls.add('requestDeletion:$confirmStoreName');
    final f = _takeFailure();
    if (f != null) throw f;
    if (store != null && confirmStoreName != store!.name) {
      throw const ApiException(
        ApiErrorCode.validationFailed,
        fields: {'confirm_store_name': 'mismatch'},
      );
    }
    final when = DateTime.utc(2026, 10, 29);
    deletionScheduledFor = when;
    store = null;
    return when;
  }
}
