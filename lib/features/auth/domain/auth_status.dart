import 'package:flutter/foundation.dart';

/// The signed-in identity as the app needs it. No tokens: those stay inside
/// the auth client and its keystore-backed storage.
@immutable
class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    required this.emailVerified,
  });

  final String id;
  final String email;
  final bool emailVerified;

  @override
  bool operator ==(Object other) =>
      other is AuthUser &&
      other.id == id &&
      other.email == email &&
      other.emailVerified == emailVerified;

  @override
  int get hashCode => Object.hash(id, email, emailVerified);
}

/// Application-wide authentication state (Phase 5 §4). Routing decisions are
/// made from this, never from a local "logged in" flag.
sealed class AuthStatus {
  const AuthStatus();
}

/// The persisted session has not been restored yet. Nothing protected may be
/// shown in this state.
class AuthInitializing extends AuthStatus {
  const AuthInitializing();
}

enum SignedOutReason {
  /// Never signed in on this device (or the session was cleared).
  none,

  /// The seller chose Sign out.
  signedOut,

  /// The session ended without the seller asking: refresh failed, it was
  /// revoked, or the server rejected the token.
  sessionExpired,
}

class SignedOut extends AuthStatus {
  const SignedOut([this.reason = SignedOutReason.none]);
  final SignedOutReason reason;
}

class SignedIn extends AuthStatus {
  const SignedIn(this.user);
  final AuthUser user;
}

/// The seller opened a password-reset link. They hold a short-lived session
/// that may only be used to choose a new password.
class PasswordRecovery extends AuthStatus {
  const PasswordRecovery(this.user);
  final AuthUser user;
}

/// Auth failures the UI distinguishes (mapped from provider error codes).
enum AuthFailure {
  /// Wrong email or password. Deliberately not "no such account" (US-002).
  invalidCredentials,

  /// The account exists but the email address is not verified yet.
  emailNotConfirmed,

  /// Sign-up with an email that already has an account (US-001).
  emailInUse,

  /// Rejected by the provider's password policy.
  weakPassword,

  /// Rejected by the provider's email validation.
  invalidEmail,

  /// The new password equals the current one.
  samePassword,

  /// Too many attempts or emails; try again later.
  rateLimited,

  /// The request did not reach the service (offline, timeout).
  network,

  /// The reset or verification link was used, expired or invalid.
  linkInvalid,

  /// Anything else; shown as a generic failure.
  unknown,
}

class AuthError implements Exception {
  const AuthError(this.failure);
  final AuthFailure failure;

  @override
  String toString() => 'AuthError(${failure.name})';
}

/// The result of a sign-up request.
enum SignUpOutcome {
  /// The account was created and a verification email was sent.
  verificationRequired,

  /// The provider signed the user in immediately (email confirmation is off
  /// in the provider configuration).
  signedIn,
}
