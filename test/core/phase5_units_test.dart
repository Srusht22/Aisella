import 'dart:async';

import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/core/backend/idempotency.dart';
import 'package:aisellia/features/auth/application/auth_controller.dart';
import 'package:aisellia/features/auth/data/auth_repository.dart';
import 'package:aisellia/features/auth/domain/auth_status.dart';
import 'package:aisellia/features/auth/domain/credentials.dart';
import 'package:aisellia/features/common/api_error_text.dart';
import 'package:aisellia/features/store/domain/store_validation.dart';
import 'package:aisellia/l10n/gen/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../helpers/fakes.dart';

void main() {
  group('API envelope', () {
    test('returns data on ok', () {
      expect(
        unwrapEnvelope({
          'ok': true,
          'data': {'id': 'x'},
        }),
        {'id': 'x'},
      );
    });

    test('maps business errors with fields, version and reference', () {
      ApiException failure(Map<String, Object?> error) {
        try {
          unwrapEnvelope({'ok': false, 'error': error});
        } on ApiException catch (e) {
          return e;
        }
        fail('expected ApiException');
      }

      final v = failure({
        'code': 'VALIDATION_FAILED',
        'details': {
          'fields': {'name': 'required'},
        },
      });
      expect(v.code, ApiErrorCode.validationFailed);
      expect(v.fields, {'name': 'required'});
      final c = failure({
        'code': 'CONFLICT_VERSION',
        'details': {'current_version': 3},
      });
      expect(c.currentVersion, 3);
      final i = failure({
        'code': 'INTERNAL',
        'details': {'ref': 'AB12CD34'},
      });
      expect((i.code, i.ref), (ApiErrorCode.internal, 'AB12CD34'));
      expect(failure({'code': 'SOMETHING_NEW'}).code, ApiErrorCode.internal);
    });

    test('malformed responses are internal errors, never crashes', () {
      expect(() => unwrapEnvelope(null), throwsA(isA<ApiException>()));
      expect(() => unwrapEnvelope('text'), throwsA(isA<ApiException>()));
    });

    test('expired JWTs map to unauthenticated, privileges to forbidden', () {
      expect(
        mapPostgrestException(
          const PostgrestException(message: 'JWT expired', code: 'PGRST303'),
        ).code,
        ApiErrorCode.unauthenticated,
      );
      expect(
        mapPostgrestException(
          const PostgrestException(message: 'denied', code: '42501'),
        ).code,
        ApiErrorCode.forbidden,
      );
      expect(
        mapPostgrestException(
          const PostgrestException(message: 'x', code: 'XX000'),
        ).code,
        ApiErrorCode.internal,
      );
    });

    test('a timeout means the outcome is unknown', () {
      expect(const ApiException(ApiErrorCode.timeout).outcomeUnknown, isTrue);
      expect(const ApiException(ApiErrorCode.network).outcomeUnknown, isFalse);
    });
  });

  group('Idempotency keys', () {
    test('are random version-4 UUIDs', () {
      final key = newIdempotencyKey();
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(key),
        isTrue,
      );
      expect(newIdempotencyKey(), isNot(key));
    });

    test('one key per intent: same payload reuses it, a change renews it', () {
      final intent = IntentKey();
      final a = intent.forPayload('shop|+9647501234567');
      expect(intent.forPayload('shop|+9647501234567'), a);
      final b = intent.forPayload('shop2|+9647501234567');
      expect(b, isNot(a));
      intent.reset();
      expect(intent.forPayload('shop2|+9647501234567'), isNot(b));
    });
  });

  group('Auth error codes', () {
    test('map to the failures the UI distinguishes', () {
      expect(
        mapAuthErrorCode('invalid_credentials', '400'),
        AuthFailure.invalidCredentials,
      );
      expect(
        mapAuthErrorCode('email_not_confirmed', '400'),
        AuthFailure.emailNotConfirmed,
      );
      expect(
        mapAuthErrorCode('user_already_exists', '422'),
        AuthFailure.emailInUse,
      );
      expect(
        mapAuthErrorCode('weak_password', '422'),
        AuthFailure.weakPassword,
      );
      expect(
        mapAuthErrorCode('over_email_send_rate_limit', '429'),
        AuthFailure.rateLimited,
      );
      expect(mapAuthErrorCode(null, '429'), AuthFailure.rateLimited);
      expect(mapAuthErrorCode('otp_expired', '403'), AuthFailure.linkInvalid);
      expect(mapAuthErrorCode('something_else', '500'), AuthFailure.unknown);
    });

    test('the provider code is shown only outside production', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(
        mapAuthErrorCode('email_address_not_authorized', '400'),
        AuthFailure.emailNotSent,
      );
      final dev = authFailureWithDetail(
        l10n,
        AuthFailure.unknown,
        isProduction: false,
        detail: 'unexpected_failure',
      );
      expect(dev, endsWith('(unexpected_failure)'));
      final prod = authFailureWithDetail(
        l10n,
        AuthFailure.unknown,
        isProduction: true,
        detail: 'unexpected_failure',
      );
      expect(prod, l10n.errGeneric);
    });
  });

  group('Credentials', () {
    test('email', () {
      expect(validateEmail(''), EmailIssue.required);
      expect(validateEmail('name'), EmailIssue.invalid);
      expect(validateEmail('a@b'), EmailIssue.invalid);
      expect(validateEmail('  seller@example.test '), isNull);
      expect(normalizeEmail('  seller@example.test '), 'seller@example.test');
    });

    test('new passwords need 8 characters, counted as characters', () {
      expect(validateNewPassword(''), PasswordIssue.required);
      expect(validateNewPassword('1234567'), PasswordIssue.tooShort);
      expect(validateNewPassword('12345678'), isNull);
      expect(validateNewPassword('وشەینهێ'), PasswordIssue.tooShort);
      expect(validateNewPassword('وشەینهێنی'), isNull);
    });

    test('sign-in only requires a password to be present', () {
      expect(validateExistingPassword('short'), isNull);
      expect(validateExistingPassword(''), PasswordIssue.required);
    });
  });

  group('Store validation', () {
    test('store name', () {
      expect(validateStoreName('   '), FieldIssue.required);
      expect(validateStoreName('x' * 61), FieldIssue.tooLong);
      expect(validateStoreName(' Shilan '), isNull);
    });

    test('contact phone is normalised to E.164', () {
      expect(parseContactPhone('0750 123 4567'), ('+9647501234567', null));
      expect(parseContactPhone('٠٧٥٠١٢٣٤٥٦٧'), ('+9647501234567', null));
      expect(parseContactPhone(''), (null, FieldIssue.required));
      expect(parseContactPhone('12345'), (null, FieldIssue.invalid));
    });

    test('fees accept Eastern digits and separators, whole units only', () {
      expect(parseFee('5000'), (5000, null));
      expect(parseFee('٥٬٠٠٠'), (5000, null));
      expect(parseFee('5,000'), (5000, null));
      expect(parseFee('0'), (0, null));
      expect(parseFee(''), (null, FieldIssue.required));
      expect(parseFee('-1'), (null, FieldIssue.invalid));
      expect(parseFee('12.5'), (null, FieldIssue.invalid));
      expect(parseFee('99999999'), (null, FieldIssue.invalid));
    });

    test('zone names are unique case-insensitively', () {
      expect(validateZoneName('erbil', taken: ['Erbil']), FieldIssue.duplicate);
      expect(validateZoneName('Duhok', taken: ['Erbil']), isNull);
      expect(validateZoneName(''), FieldIssue.required);
    });

    test('server field rules map to the same issues', () {
      expect(fieldIssueFromServer('duplicate'), FieldIssue.duplicate);
      expect(fieldIssueFromServer('too_long'), FieldIssue.tooLong);
      expect(fieldIssueFromServer('out_of_range'), FieldIssue.invalid);
    });
  });

  group('AuthController', () {
    late FakeAuthRepository repo;
    late ProviderContainer container;

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    setUp(() {
      repo = FakeAuthRepository();
      container = ProviderContainer(
        overrides: [authRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
    });

    test('starts initializing, then follows the restored session', () async {
      expect(container.read(authControllerProvider), isA<AuthInitializing>());
      await settle();
      expect(container.read(authControllerProvider), isA<SignedOut>());
    });

    test(
      'a sign-out the seller did not ask for is an expired session',
      () async {
        container.read(authControllerProvider);
        await settle();
        repo.emit(AuthEventKind.signedIn, testUser);
        await settle();
        expect(container.read(authControllerProvider), isA<SignedIn>());
        repo.emit(AuthEventKind.signedOut);
        await settle();
        final state = container.read(authControllerProvider) as SignedOut;
        expect(state.reason, SignedOutReason.sessionExpired);
      },
    );

    test('a requested sign-out is reported as such', () async {
      container.read(authControllerProvider);
      await settle();
      repo.emit(AuthEventKind.signedIn, testUser);
      await settle();
      await container.read(authControllerProvider.notifier).signOut();
      await settle();
      final state = container.read(authControllerProvider) as SignedOut;
      expect(state.reason, SignedOutReason.signedOut);
    });

    test(
      'a recovery session stays restricted until the password changes',
      () async {
        container.read(authControllerProvider);
        await settle();
        repo.emit(AuthEventKind.passwordRecovery, testUser);
        await settle();
        repo.emit(AuthEventKind.tokenRefreshed, testUser);
        await settle();
        expect(container.read(authControllerProvider), isA<PasswordRecovery>());
        await container
            .read(authControllerProvider.notifier)
            .updatePassword('new-password-1');
        expect(container.read(authControllerProvider), isA<SignedIn>());
      },
    );

    test('a failed password change keeps the recovery state', () async {
      container.read(authControllerProvider);
      await settle();
      repo.emit(AuthEventKind.passwordRecovery, testUser);
      await settle();
      repo.failNext = AuthFailure.samePassword;
      await expectLater(
        container.read(authControllerProvider.notifier).updatePassword('x' * 8),
        throwsA(isA<AuthError>()),
      );
      expect(container.read(authControllerProvider), isA<PasswordRecovery>());
    });

    test('a server-rejected session signs out locally', () async {
      container.read(authControllerProvider);
      await settle();
      repo.emit(AuthEventKind.signedIn, testUser);
      await settle();
      await container.read(authControllerProvider.notifier).sessionRejected();
      final state = container.read(authControllerProvider) as SignedOut;
      expect(state.reason, SignedOutReason.sessionExpired);
      expect(repo.calls, contains('clearLocalSession'));
    });
  });

  test('auth link constants match the configured redirect URLs', () {
    expect(AuthLinks.callback, 'app.aisellia://auth/callback');
    expect(AuthLinks.passwordReset, 'app.aisellia://auth/reset');
    unawaited(Future<void>.value());
  });
}
