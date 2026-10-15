import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Deployment environment, selected at build time with `ENV_NAME`
/// (see config/README.md).
enum AppEnvironment { dev, staging, prod }

/// Thrown when the build configuration is invalid. Caught at bootstrap and
/// shown through the startup error screen instead of crashing.
class AppConfigException implements Exception {
  const AppConfigException(this.message);

  /// Developer-facing reason. Never shown verbatim to end users.
  final String message;

  @override
  String toString() => 'AppConfigException: $message';
}

/// Public, non-secret build configuration. Privileged credentials never
/// belong here (Phase 3 deployment-and-operations §3): the app only ever
/// receives the project URL and the *publishable* (anon) key, which is safe
/// to ship because every table is protected by RLS and every mutation by an
/// authorizing database function.
@immutable
class AppConfig {
  const AppConfig({
    required this.environment,
    required this.sampleData,
    this.supabaseUrl,
    this.supabasePublishableKey = '',
  });

  /// Parses raw values as passed via `--dart-define(-from-file)`.
  /// Empty strings mean "not provided".
  factory AppConfig.fromValues({
    String? envName,
    String? sampleData,
    String? supabaseUrl,
    String? supabasePublishableKey,
  }) {
    final env = switch ((envName ?? '').trim()) {
      '' || 'dev' => AppEnvironment.dev,
      'staging' => AppEnvironment.staging,
      'prod' => AppEnvironment.prod,
      final other => throw AppConfigException('Unknown ENV_NAME "$other".'),
    };
    final sample = switch ((sampleData ?? '').trim()) {
      '' => env == AppEnvironment.dev,
      'true' => true,
      'false' => false,
      final other => throw AppConfigException(
        'SAMPLE_DATA must be "true" or "false", got "$other".',
      ),
    };
    if (env == AppEnvironment.prod && sample) {
      throw const AppConfigException(
        'SAMPLE_DATA must be false in prod builds.',
      );
    }

    final rawUrl = (supabaseUrl ?? '').trim();
    final key = (supabasePublishableKey ?? '').trim();
    if (rawUrl.isEmpty || key.isEmpty) {
      throw const AppConfigException(
        'SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are required '
        '(see config/README.md).',
      );
    }
    final url = Uri.tryParse(rawUrl);
    if (url == null || !url.hasAuthority || url.host.isEmpty) {
      throw const AppConfigException('SUPABASE_URL is not a valid URL.');
    }
    // Plain HTTP is accepted only for a local development stack.
    if (url.scheme != 'https' &&
        !(env == AppEnvironment.dev && url.scheme == 'http')) {
      throw const AppConfigException(
        'SUPABASE_URL must use https outside dev builds.',
      );
    }
    if (isPrivilegedKey(key)) {
      throw const AppConfigException(
        'SUPABASE_PUBLISHABLE_KEY looks like a secret or service-role key. '
        'Only the publishable (anon) key may be built into the app.',
      );
    }

    return AppConfig(
      environment: env,
      sampleData: sample,
      supabaseUrl: url,
      supabasePublishableKey: key,
    );
  }

  /// Reads the compile-time defines.
  factory AppConfig.fromEnvironment() => AppConfig.fromValues(
    envName: const String.fromEnvironment('ENV_NAME'),
    sampleData: const String.fromEnvironment('SAMPLE_DATA'),
    supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
    supabasePublishableKey: const String.fromEnvironment(
      'SUPABASE_PUBLISHABLE_KEY',
    ),
  );

  /// True for keys that must never reach a client: new-style secret keys and
  /// legacy JWT keys whose `role` claim is `service_role`.
  static bool isPrivilegedKey(String key) {
    if (key.startsWith('sb_secret_')) return true;
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final claims = jsonDecode(payload);
      return claims is Map && claims['role'] == 'service_role';
    } on FormatException {
      return false;
    }
  }

  final AppEnvironment environment;

  /// Whether screens may show clearly labelled sample data for design review.
  final bool sampleData;

  /// Supabase project URL. Null only in widget tests that fake the backend.
  final Uri? supabaseUrl;

  /// Publishable (anon) key: public by design, protected by RLS.
  final String supabasePublishableKey;

  bool get isProduction => environment == AppEnvironment.prod;
}

/// Overridden in `bootstrap()`; reading it un-overridden is a programming error.
final appConfigProvider = Provider<AppConfig>(
  (ref) => throw StateError('appConfigProvider must be overridden.'),
);
