import 'package:flutter/foundation.dart';

import '../../../core/formatting/money.dart';

/// Where the seller is in store setup (Phase 2 AU-07..09). Persisted on the
/// server so setup resumes at the first incomplete step after a restart.
enum OnboardingStep { zones, payments, done }

/// Suggested business cities (Phase 2 AU-07). Stored by key; any other city
/// is stored as typed.
const suggestedCities = ['sulaymaniyah', 'erbil', 'duhok', 'halabja'];

/// The seller's store as returned by the API (server state; never edited in
/// place: changes go through the store repository).
@immutable
class Store {
  const Store({
    required this.id,
    required this.name,
    required this.contactPhone,
    required this.currency,
    required this.replyLocale,
    required this.businessCity,
    required this.codEnabled,
    required this.otherPaymentEnabled,
    required this.onboardingStep,
    required this.currencyLocked,
    required this.version,
  });

  factory Store.fromJson(Map<String, dynamic> json) => Store(
    id: json['id'] as String,
    name: json['name'] as String,
    contactPhone: json['contact_phone'] as String,
    currency: json['currency'] == 'USD' ? Currency.usd : Currency.iqd,
    replyLocale: json['reply_locale'] as String,
    businessCity: json['business_city'] as String,
    codEnabled: json['cod_enabled'] as bool,
    otherPaymentEnabled: json['other_payment_enabled'] as bool,
    onboardingStep: OnboardingStep.values.firstWhere(
      (s) => s.name == json['onboarding_step'],
      orElse: () => OnboardingStep.done,
    ),
    currencyLocked: json['currency_locked'] as bool? ?? false,
    version: json['version'] as int,
  );

  final String id;
  final String name;

  /// E.164 (`+9647XXXXXXXXX`).
  final String contactPhone;
  final Currency currency;

  /// Language of customer replies: `ckb` or `en` (may differ from the app).
  final String replyLocale;

  /// A [suggestedCities] key or the city as typed.
  final String businessCity;
  final bool codEnabled;
  final bool otherPaymentEnabled;
  final OnboardingStep onboardingStep;

  /// True after the first approved order: the currency can no longer change.
  final bool currencyLocked;

  /// Optimistic-concurrency version, sent back with every update.
  final int version;

  @override
  bool operator ==(Object other) =>
      other is Store && other.id == id && other.version == version;

  @override
  int get hashCode => Object.hash(id, version);
}

String currencyCode(Currency c) => c == Currency.usd ? 'USD' : 'IQD';

/// Values entered in store setup (AU-07), already normalised.
@immutable
class StoreDraft {
  const StoreDraft({
    required this.name,
    required this.contactPhone,
    required this.currency,
    required this.replyLocale,
    required this.businessCity,
  });

  final String name;
  final String contactPhone;
  final Currency currency;
  final String replyLocale;
  final String businessCity;

  /// Canonical form, used to keep one idempotency key per unchanged request.
  String get canonical => [
    name,
    contactPhone,
    currencyCode(currency),
    replyLocale,
    businessCity,
  ].join('\u0000');
}

@immutable
class DeliveryZone {
  const DeliveryZone({
    required this.id,
    required this.name,
    required this.fee,
    required this.timeText,
    required this.version,
  });

  factory DeliveryZone.fromJson(Map<String, dynamic> json) => DeliveryZone(
    id: json['id'] as String,
    name: json['name'] as String,
    fee: json['fee'] as int,
    timeText: json['time_text'] as String?,
    version: json['version'] as int,
  );

  final String id;
  final String name;

  /// Whole units of the store currency (Phase 1 BR-12).
  final int fee;
  final String? timeText;
  final int version;
}

/// Everything the app needs to route a signed-in seller (api.get_my_context).
@immutable
class AccountContext {
  const AccountContext({
    required this.userId,
    required this.email,
    required this.emailVerified,
    required this.deletionPending,
    required this.store,
  });

  factory AccountContext.fromJson(Map<String, dynamic> json) => AccountContext(
    userId: json['user_id'] as String,
    email: json['email'] as String? ?? '',
    emailVerified: json['email_verified'] as bool? ?? false,
    deletionPending: json['deletion_pending'] as bool? ?? false,
    store: json['store'] is Map
        ? Store.fromJson((json['store'] as Map).cast<String, dynamic>())
        : null,
  );

  final String userId;
  final String email;
  final bool emailVerified;

  /// The seller asked to delete the account; the store is no longer usable.
  final bool deletionPending;
  final Store? store;

  AccountContext withStore(Store store) => AccountContext(
    userId: userId,
    email: email,
    emailVerified: emailVerified,
    deletionPending: deletionPending,
    store: store,
  );
}
