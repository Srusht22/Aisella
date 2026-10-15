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
/// belong here (Phase 3 deployment-and-operations §3).
@immutable
class AppConfig {
  const AppConfig({required this.environment, required this.sampleData});

  /// Parses raw values as passed via `--dart-define(-from-file)`.
  /// Empty strings mean "not provided".
  factory AppConfig.fromValues({String? envName, String? sampleData}) {
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
    return AppConfig(environment: env, sampleData: sample);
  }

  /// Reads the compile-time defines.
  factory AppConfig.fromEnvironment() => AppConfig.fromValues(
    envName: const String.fromEnvironment('ENV_NAME'),
    sampleData: const String.fromEnvironment('SAMPLE_DATA'),
  );

  final AppEnvironment environment;

  /// Whether screens may show clearly labelled sample data for design review.
  final bool sampleData;

  bool get isProduction => environment == AppEnvironment.prod;
}

/// Overridden in `bootstrap()`; reading it un-overridden is a programming error.
final appConfigProvider = Provider<AppConfig>(
  (ref) => throw StateError('appConfigProvider must be overridden.'),
);
