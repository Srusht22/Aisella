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

  /// A variant that has stock or history cannot be removed; archive it.
  /// `details['variant_ids']` lists them.
  variantInUse,

  /// The stock changed since the seller looked (`details['current_stock']`).
  stockChanged,

  /// The result would be negative (`details['current_stock']`).
  insufficientStock,

  /// The product does not track stock.
  stockNotTracked,

  /// The order is not in a status that allows this change
  /// (`details['current_status']`). For a repeated approval this means it
  /// is already approved.
  invalidTransition,

  /// Required order fields are missing (`details['issues']`).
  incompleteOrder,

  /// Catalog prices changed since the quote (`details['items']`: item_id,
  /// quoted, current). The seller chooses per line (BR-23).
  priceChanged,

  /// Lines that can no longer be sold (`details['lines']`: item_id, reason).
  lineUnavailable,

  /// The account's email is not confirmed; approval needs it.
  emailNotVerified,

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
    this.details = const {},
  });

  final ApiErrorCode code;

  /// Field-level validation failures, `{field: rule}`.
  final Map<String, String> fields;

  /// For [ApiErrorCode.conflictVersion]: the server's current version.
  final int? currentVersion;

  /// Support reference for [ApiErrorCode.internal].
  final String? ref;

  /// The error's other details (for example `current_stock`).
  final Map<String, dynamic> details;

  /// For stock errors: the server's current stock.
  int? get currentStock => switch (details['current_stock']) {
    final int v => v,
    _ => null,
  };

  /// For order errors: the order's current status (wire value).
  String? get currentStatus => details['current_status'] as String?;

  /// Entries of a list detail (`lines`, `items`, `issues`).
  List<Map<String, dynamic>> detailList(String key) => [
    for (final e in details[key] as List? ?? const [])
      if (e is Map) e.cast<String, dynamic>(),
  ];

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
  'VARIANT_IN_USE': ApiErrorCode.variantInUse,
  'STOCK_CHANGED': ApiErrorCode.stockChanged,
  'INSUFFICIENT_STOCK': ApiErrorCode.insufficientStock,
  'STOCK_NOT_TRACKED': ApiErrorCode.stockNotTracked,
  'INVALID_TRANSITION': ApiErrorCode.invalidTransition,
  'INCOMPLETE_ORDER': ApiErrorCode.incompleteOrder,
  'PRICE_CHANGED': ApiErrorCode.priceChanged,
  'LINE_UNAVAILABLE': ApiErrorCode.lineUnavailable,
  'EMAIL_NOT_VERIFIED': ApiErrorCode.emailNotVerified,
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
    details: details,
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
