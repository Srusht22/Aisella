import '../../core/backend/api.dart';
import '../../core/l10n/l10n.dart';
import '../auth/domain/auth_status.dart';

/// Localized, user-facing text for a failed API call (P-ERR-ACTION). Never
/// includes provider or database messages; internal errors carry only the
/// support reference.
String apiErrorText(AppLocalizations l10n, ApiException e) => switch (e.code) {
  ApiErrorCode.network || ApiErrorCode.timeout => l10n.errNetwork,
  ApiErrorCode.rateLimited => l10n.errRateLimited,
  ApiErrorCode.conflictVersion => l10n.errConflictReloaded,
  ApiErrorCode.currencyLocked => l10n.currencyLockedNote,
  ApiErrorCode.internal when e.ref != null =>
    '${l10n.errorServer} ${l10n.errorReference(e.ref!)}',
  ApiErrorCode.internal => l10n.errorServer,
  _ => l10n.errSaveFailed,
};

/// [authFailureText] plus the provider's error code in non-production
/// builds, so a test deployment can be diagnosed. Production never shows it.
String authFailureWithDetail(
  AppLocalizations l10n,
  AuthFailure f, {
  required bool isProduction,
  String? detail,
}) {
  final text = authFailureText(l10n, f);
  return isProduction || detail == null ? text : '$text ($detail)';
}

/// Localized text for an auth failure. No provider wording reaches the UI.
String authFailureText(AppLocalizations l10n, AuthFailure f) => switch (f) {
  AuthFailure.invalidCredentials => l10n.errInvalidCredentials,
  AuthFailure.emailNotConfirmed => l10n.errEmailNotConfirmed,
  AuthFailure.emailInUse => l10n.errEmailInUse,
  AuthFailure.weakPassword => l10n.errWeakPassword,
  AuthFailure.invalidEmail => l10n.errEmailInvalid,
  AuthFailure.samePassword => l10n.errSamePassword,
  AuthFailure.rateLimited => l10n.errRateLimited,
  AuthFailure.network => l10n.errNetwork,
  AuthFailure.linkInvalid => l10n.errLinkInvalid,
  AuthFailure.emailNotSent => l10n.errEmailNotSent,
  AuthFailure.unknown => l10n.errGeneric,
};
