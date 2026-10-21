import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backend/api.dart';
import '../data/auth_repository.dart';
import '../domain/auth_status.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => SupabaseAuthRepository(ref.watch(supabaseClientProvider)),
);

/// The single source of truth for "who is signed in" (Phase 5 §4). Screens
/// call its methods; the router reads its state. Nothing else decides whether
/// protected content may be shown.
final authControllerProvider = NotifierProvider<AuthController, AuthStatus>(
  AuthController.new,
);

class AuthController extends Notifier<AuthStatus> {
  StreamSubscription<AuthEvent>? _events;

  /// Set while a sign-out requested by the seller is in progress, so the
  /// resulting provider event is not mistaken for an expired session.
  bool _signOutRequested = false;

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  @override
  AuthStatus build() {
    final repo = ref.watch(authRepositoryProvider);
    _events = repo.events.listen(_onEvent);
    ref.onDispose(() => _events?.cancel());
    return const AuthInitializing();
  }

  void _onEvent(AuthEvent event) {
    final user = event.user;
    switch (event.kind) {
      case AuthEventKind.initial:
        state = user == null ? const SignedOut() : SignedIn(user);
      case AuthEventKind.signedIn:
        if (user != null) state = SignedIn(user);
      case AuthEventKind.passwordRecovery:
        if (user != null) state = PasswordRecovery(user);
      case AuthEventKind.userUpdated:
      case AuthEventKind.tokenRefreshed:
        if (user == null) return;
        // A recovery session stays restricted until the password is changed
        // (handled in [updatePassword]); other states get fresh user data.
        if (state is SignedIn) state = SignedIn(user);
      case AuthEventKind.signedOut:
        final current = state;
        final reason = _signOutRequested
            ? SignedOutReason.signedOut
            // Already signed out (for example by [sessionRejected]): the
            // provider's own event must not overwrite why.
            : current is SignedOut
            ? current.reason
            : current is AuthInitializing
            ? SignedOutReason.none
            : SignedOutReason.sessionExpired;
        _signOutRequested = false;
        state = SignedOut(reason);
    }
  }

  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String termsVersion,
    SignUpProfile? profile,
  }) => _repo.signUp(
    email: email,
    password: password,
    termsVersion: termsVersion,
    profile: profile,
  );

  Future<void> signIn({required String email, required String password}) =>
      _repo.signIn(email: email, password: password);

  /// Signs out on this device (or everywhere). Afterwards no protected
  /// state is reachable: providers scoped to the user are rebuilt empty and
  /// the router leaves every protected route.
  Future<void> signOut({bool allDevices = false}) async {
    _signOutRequested = true;
    await _repo.signOut(allDevices: allDevices);
    if (state is! SignedOut) state = const SignedOut(SignedOutReason.signedOut);
  }

  /// Called when the server rejected the session (401). The local session is
  /// removed and the seller is asked to sign in again.
  Future<void> sessionRejected() async {
    if (state is SignedOut) return;
    state = const SignedOut(SignedOutReason.sessionExpired);
    await _repo.clearLocalSession();
  }

  Future<void> resendVerification(String email) =>
      _repo.resendVerification(email);

  Future<void> requestPasswordReset(String email) =>
      _repo.requestPasswordReset(email);

  /// Sets a new password. From a recovery link this also ends the restricted
  /// recovery state; the seller continues signed in.
  Future<void> updatePassword(String newPassword) async {
    await _repo.updatePassword(newPassword);
    final current = state;
    if (current is PasswordRecovery) state = SignedIn(current.user);
  }

  /// Confirms the signed-in seller's password with a fresh sign-in, which
  /// renews the session's authentication time (required by destructive
  /// account actions).
  Future<void> reauthenticate(String password) async {
    final current = state;
    if (current is! SignedIn) throw const AuthError(AuthFailure.unknown);
    await _repo.signIn(email: current.user.email, password: password);
  }
}
