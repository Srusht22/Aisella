import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The Supabase client, created in `bootstrap()` after `Supabase.initialize`.
/// Repositories receive it through this provider so tests can substitute
/// fakes, and integration tests a client pointed at the local stack.
final supabaseClientProvider = Provider<SupabaseClient>(
  (ref) => throw StateError('supabaseClientProvider must be overridden.'),
);

/// Error codes of the API contract (Phase 3 api-and-service-contracts §2),
/// plus client-side transport outcomes.
enum ApiErrorCode {
  validationFailed,
  unauthenticated,
  forbidden,
  notFound,
  conflictVersion,
  limitExceeded,
  currencyLocked,
  idempotencyKeyReused,
  rateLimited,

  /// A destructive account action needs a fresh password sign-in.
  reauthenticationRequired,

  /// The request could not be sent (offline, DNS, connection refused).
  /// Nothing reached the server.
  network,

  /// No response arrived in time. The operation **may** have succeeded:
  /// callers reconcile with the server before retrying (P-ERR-UNKNOWN).
  timeout,

  /// Server-side unexpected failure; `ref` identifies it in the logs.
  internal,
}

/// A failed API call. Messages are never shown verbatim: screens map [code]
/// and [fields] to localized text.
class ApiException implements Exception {
  const ApiException(
    this.code, {
    this.fields = const {},
    this.currentVersion,
    this.ref,
  });

  final ApiErrorCode code;

  /// Field-level validation failures, `{field: rule}`.
  final Map<String, String> fields;

  /// For [ApiErrorCode.conflictVersion]: the server's current version.
  final int? currentVersion;

  /// Support reference for [ApiErrorCode.internal].
  final String? ref;

  /// Whether the outcome of a mutation is unknown and must be reconciled.
  bool get outcomeUnknown => code == ApiErrorCode.timeout;

  @override
  String toString() => 'ApiException(${code.name})';
}

const _codes = <String, ApiErrorCode>{
  'VALIDATION_FAILED': ApiErrorCode.validationFailed,
  'UNAUTHENTICATED': ApiErrorCode.unauthenticated,
  'FORBIDDEN': ApiErrorCode.forbidden,
  'NOT_FOUND': ApiErrorCode.notFound,
  'CONFLICT_VERSION': ApiErrorCode.conflictVersion,
  'LIMIT_EXCEEDED': ApiErrorCode.limitExceeded,
  'CURRENCY_LOCKED': ApiErrorCode.currencyLocked,
  'IDEMPOTENCY_KEY_REUSED': ApiErrorCode.idempotencyKeyReused,
  'RATE_LIMITED': ApiErrorCode.rateLimited,
  'REAUTHENTICATION_REQUIRED': ApiErrorCode.reauthenticationRequired,
  'INTERNAL': ApiErrorCode.internal,
};

/// Default client timeout for RPC calls (Phase 3 Flutter §13).
const apiTimeout = Duration(seconds: 15);

/// Calls an `api.*` function and unwraps the `{ok, data | error}` envelope.
/// Throws [ApiException] for business errors and transport failures.
Future<Map<String, dynamic>> callApi(
  SupabaseClient client,
  String function, {
  Map<String, dynamic>? params,
  Duration timeout = apiTimeout,
}) async {
  final Object? raw;
  try {
    raw = await client.rpc<Object?>(function, params: params).timeout(timeout);
  } on TimeoutException {
    throw const ApiException(ApiErrorCode.timeout);
  } on PostgrestException catch (e) {
    throw mapPostgrestException(e);
  } on AuthException {
    // Refreshing the session failed: the caller must sign in again.
    throw const ApiException(ApiErrorCode.unauthenticated);
  } on Exception {
    // Transport failures (socket, TLS, HTTP client): nothing was processed.
    throw const ApiException(ApiErrorCode.network);
  }
  return unwrapEnvelope(raw);
}

/// Parses the function envelope. Exposed for tests.
Map<String, dynamic> unwrapEnvelope(Object? raw) {
  if (raw is! Map) throw const ApiException(ApiErrorCode.internal);
  final envelope = raw.cast<String, dynamic>();
  if (envelope['ok'] == true) {
    final data = envelope['data'];
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }
  final error = envelope['error'];
  if (error is! Map) throw const ApiException(ApiErrorCode.internal);
  final details = error['details'] is Map
      ? (error['details'] as Map).cast<String, dynamic>()
      : <String, dynamic>{};
  final fields = details['fields'] is Map
      ? (details['fields'] as Map).map((k, v) => MapEntry('$k', '$v'))
      : <String, String>{};
  final version = details['current_version'];
  throw ApiException(
    _codes[error['code']] ?? ApiErrorCode.internal,
    fields: fields,
    currentVersion: version is int ? version : null,
    ref: details['ref'] is String ? details['ref'] as String : null,
  );
}

/// PostgREST errors: an expired or missing JWT is unauthenticated; a missing
/// privilege is forbidden; anything else is internal (no details leaked).
ApiException mapPostgrestException(PostgrestException e) {
  final status = int.tryParse(e.code ?? '');
  if (e.code == 'PGRST301' || e.code == 'PGRST303' || status == 401) {
    return const ApiException(ApiErrorCode.unauthenticated);
  }
  if (e.code == '42501' || status == 403) {
    return const ApiException(ApiErrorCode.forbidden);
  }
  return const ApiException(ApiErrorCode.internal);
}
