import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import '../domain/auth_status.dart';

/// Deep links that email links open (configured in Supabase Auth's redirect
/// allow-list, AndroidManifest.xml and Info.plist). Provisional scheme until
/// AD-10 fixes the app identifier.
abstract final class AuthLinks {
  static const callback = 'app.aisellia://auth/callback';
  static const passwordReset = 'app.aisellia://auth/reset';
}

/// What changed in the provider's session.
enum AuthEventKind {
  initial,
  signedIn,
  signedOut,
  passwordRecovery,
  userUpdated,
  tokenRefreshed,
}

class AuthEvent {
  const AuthEvent(this.kind, this.user);
  final AuthEventKind kind;
  final AuthUser? user;
}

/// Authentication operations. All credential handling is delegated to the
/// provider (Supabase Auth); the app never stores or hashes passwords.
abstract interface class AuthRepository {
  /// Session changes, starting with the restored (initial) session.
  Stream<AuthEvent> get events;

  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String termsVersion,
  });

  Future<void> signIn({required String email, required String password});

  /// Revokes the session on the server (this device, or all devices) and
  /// removes it from the device.
  Future<void> signOut({bool allDevices = false});

  /// Ends the local session without a server call; used when the server
  /// already rejected it.
  Future<void> clearLocalSession();

  Future<void> resendVerification(String email);

  /// Always completes normally for unknown addresses (no enumeration, US-003).
  Future<void> requestPasswordReset(String email);

  Future<void> updatePassword(String newPassword);

  /// Fresh user data from the server (for example after the email was
  /// verified on another device).
  Future<AuthUser?> reloadUser();
}

const _authTimeout = Duration(seconds: 20);

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  @override
  Stream<AuthEvent> get events => _auth.onAuthStateChange
      .map((state) {
        final kind = switch (state.event) {
          AuthChangeEvent.initialSession => AuthEventKind.initial,
          AuthChangeEvent.signedIn => AuthEventKind.signedIn,
          AuthChangeEvent.signedOut => AuthEventKind.signedOut,
          AuthChangeEvent.passwordRecovery => AuthEventKind.passwordRecovery,
          AuthChangeEvent.userUpdated => AuthEventKind.userUpdated,
          AuthChangeEvent.tokenRefreshed => AuthEventKind.tokenRefreshed,
          _ => null,
        };
        if (kind == null) return null;
        return AuthEvent(kind, _toUser(state.session?.user));
      })
      .where((e) => e != null)
      .cast<AuthEvent>()
      // Errors (for example an invalid deep-link code) are surfaced through
      // the next state change; they must not crash the listener.
      .handleError((Object _) {});

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String termsVersion,
  }) => _guard(() async {
    final res = await _auth.signUp(
      email: email,
      password: password,
      data: {'terms_version': termsVersion},
      emailRedirectTo: AuthLinks.callback,
    );
    // With email confirmation on, Supabase answers an existing address with
    // an obfuscated user that has no identities instead of an error.
    final identities = res.user?.identities;
    if (res.user != null && identities != null && identities.isEmpty) {
      throw const AuthError(AuthFailure.emailInUse);
    }
    return res.session != null
        ? SignUpOutcome.signedIn
        : SignUpOutcome.verificationRequired;
  });

  @override
  Future<void> signIn({required String email, required String password}) =>
      _guard(() => _auth.signInWithPassword(email: email, password: password));

  @override
  Future<void> signOut({bool allDevices = false}) async {
    try {
      await _auth
          .signOut(scope: allDevices ? SignOutScope.global : SignOutScope.local)
          .timeout(_authTimeout);
    } on Object {
      // The server could not be told (offline): the local session is still
      // removed so this device no longer has access. The refresh token then
      // expires on the server by itself.
      await clearLocalSession();
    }
  }

  @override
  Future<void> clearLocalSession() async {
    try {
      await _auth.signOut(scope: SignOutScope.local);
    } on Object {
      // Already gone.
    }
  }

  @override
  Future<void> resendVerification(String email) => _guard(
    () => _auth.resend(
      type: OtpType.signup,
      email: email,
      emailRedirectTo: AuthLinks.callback,
    ),
  );

  @override
  Future<void> requestPasswordReset(String email) => _guard(
    () =>
        _auth.resetPasswordForEmail(email, redirectTo: AuthLinks.passwordReset),
  );

  @override
  Future<void> updatePassword(String newPassword) =>
      _guard(() => _auth.updateUser(UserAttributes(password: newPassword)));

  @override
  Future<AuthUser?> reloadUser() async {
    try {
      final res = await _auth.getUser().timeout(_authTimeout);
      return _toUser(res.user);
    } on Object {
      return null;
    }
  }

  static AuthUser? _toUser(User? user) => user == null
      ? null
      : AuthUser(
          id: user.id,
          email: user.email ?? '',
          emailVerified: user.emailConfirmedAt != null,
        );

  /// Runs a provider call with a timeout and maps every failure to an
  /// [AuthError] (no provider messages reach the UI).
  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call().timeout(_authTimeout);
    } on AuthError {
      rethrow;
    } on TimeoutException {
      throw const AuthError(AuthFailure.network);
    } on SocketException {
      throw const AuthError(AuthFailure.network);
    } on AuthRetryableFetchException {
      throw const AuthError(AuthFailure.network);
    } on AuthWeakPasswordException {
      throw const AuthError(AuthFailure.weakPassword);
    } on AuthException catch (e) {
      throw AuthError(mapAuthErrorCode(e.code, e.statusCode));
    } on Exception {
      // Transport failures (HTTP client, TLS): the request did not complete.
      throw const AuthError(AuthFailure.network);
    }
  }
}

/// Maps Supabase Auth error codes (https://supabase.com/docs/guides/auth/debugging/error-codes)
/// to the failures the UI distinguishes. Exposed for tests.
AuthFailure mapAuthErrorCode(String? code, String? statusCode) =>
    switch (code) {
      'invalid_credentials' => AuthFailure.invalidCredentials,
      'email_not_confirmed' => AuthFailure.emailNotConfirmed,
      'user_already_exists' || 'email_exists' => AuthFailure.emailInUse,
      'weak_password' => AuthFailure.weakPassword,
      'email_address_invalid' ||
      'validation_failed' => AuthFailure.invalidEmail,
      'same_password' => AuthFailure.samePassword,
      'over_request_rate_limit' ||
      'over_email_send_rate_limit' => AuthFailure.rateLimited,
      'otp_expired' ||
      'flow_state_expired' ||
      'flow_state_not_found' ||
      'bad_code_verifier' => AuthFailure.linkInvalid,
      _ when statusCode == '429' => AuthFailure.rateLimited,
      _ => AuthFailure.unknown,
    };
