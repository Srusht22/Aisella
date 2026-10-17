// End-to-end tests against a LOCAL Supabase stack (`supabase start`): real
// GoTrue (auth, email via Mailpit), PostgREST and Postgres with the Phase 5
// migration. They use the app's own repository classes.
//
//   eval "$(supabase status -o env | grep -E '^(API_URL|PUBLISHABLE_KEY|MAILPIT_URL)=')"
//   SUPABASE_TEST_URL=$API_URL SUPABASE_TEST_PUBLISHABLE_KEY=$PUBLISHABLE_KEY \
//   MAILPIT_TEST_URL=$MAILPIT_URL flutter test --tags backend
//
// Without those variables every test is skipped. They refuse non-local URLs.
@Tags(['backend'])
library;

import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/core/formatting/money.dart';
import 'package:aisellia/features/auth/data/auth_repository.dart';
import 'package:aisellia/features/auth/domain/auth_status.dart';
import 'package:aisellia/features/store/data/store_repository.dart';
import 'package:aisellia/features/store/domain/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import 'backend_support.dart';

StoreDraft _draft(String name) => StoreDraft(
  name: name,
  contactPhone: '+9647501234567',
  currency: Currency.iqd,
  replyLocale: 'ckb',
  businessCity: 'erbil',
);

Future<ApiErrorCode> _apiError(Future<Object?> call) async {
  try {
    await call;
  } on ApiException catch (e) {
    return e.code;
  }
  fail('expected an ApiException');
}

void main() {
  group('Supabase Auth (real GoTrue)', skip: backendSkip, () {
    test('sign-up requires email verification before sign-in', () async {
      final email = uniqueEmail('verify');
      final auth = SupabaseAuthRepository(backendClient());
      expect(
        await auth.signUp(
          email: email,
          password: testPassword,
          termsVersion: '2026-10',
        ),
        SignUpOutcome.verificationRequired,
      );
      await expectLater(
        auth.signIn(email: email, password: testPassword),
        throwsA(
          isA<AuthError>().having(
            (e) => e.failure,
            'failure',
            AuthFailure.emailNotConfirmed,
          ),
        ),
      );
      final redirect = await openLink(await linkFromMail(email));
      expect(redirect.toString(), startsWith(AuthLinks.callback));
      await auth.signIn(email: email, password: testPassword);
    });

    test(
      'signing up an existing email is reported, without a second account',
      () async {
        final email = uniqueEmail('dup');
        await verifiedSeller(email);
        final auth = SupabaseAuthRepository(backendClient());
        await expectLater(
          auth.signUp(
            email: email,
            password: 'another-password-1',
            termsVersion: '2026-10',
          ),
          throwsA(
            isA<AuthError>().having(
              (e) => e.failure,
              'failure',
              AuthFailure.emailInUse,
            ),
          ),
        );
        // The original password still works: nothing was overwritten.
        await SupabaseAuthRepository(backendClient())
            .signIn(email: email, password: testPassword);
      },
    );

    test(
      'wrong password and unknown account give the same generic failure',
      () async {
        final email = uniqueEmail('wrong');
        await verifiedSeller(email);
        for (final (who, pass) in [
          (email, 'wrong-password'),
          (uniqueEmail('nobody'), testPassword),
        ]) {
          await expectLater(
            SupabaseAuthRepository(backendClient())
                .signIn(email: who, password: pass),
            throwsA(
              isA<AuthError>().having(
                (e) => e.failure,
                'failure',
                AuthFailure.invalidCredentials,
              ),
            ),
          );
        }
      },
    );

    test(
      'short passwords are rejected by the provider, not only the app',
      () async {
        await expectLater(
          SupabaseAuthRepository(backendClient()).signUp(
            email: uniqueEmail('short'),
            password: '1234567',
            termsVersion: '2026-10',
          ),
          throwsA(isA<AuthError>()),
        );
      },
    );

    test('password reset: same answer for unknown emails; the link sets a new password', () async {
      // Unknown address: completes normally (no enumeration).
      await SupabaseAuthRepository(backendClient())
          .requestPasswordReset(uniqueEmail('ghost'));

      final email = uniqueEmail('reset');
      await verifiedSeller(email);
      final client = backendClient();
      final auth = SupabaseAuthRepository(client);
      final events = <AuthEventKind>[];
      final sub = auth.events.listen((e) => events.add(e.kind));
      await auth.requestPasswordReset(email);
      final redirect = await openLink(
        await linkFromMail(email, type: 'recovery'),
      );
      expect(redirect.toString(), startsWith(AuthLinks.passwordReset));
      final code = redirect.queryParameters['code'];
      expect(code, isNotNull, reason: 'PKCE code in the deep link');
      await client.auth.exchangeCodeForSession(code!);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events, contains(AuthEventKind.passwordRecovery));
      await auth.updatePassword('a-brand-new-password');
      await sub.cancel();

      await expectLater(
        SupabaseAuthRepository(backendClient())
            .signIn(email: email, password: testPassword),
        throwsA(isA<AuthError>()),
      );
      await SupabaseAuthRepository(backendClient())
          .signIn(email: email, password: 'a-brand-new-password');
    });

    test('sign-out revokes the refresh token on the server', () async {
      final client = await verifiedSeller(uniqueEmail('signout'));
      final refresh = client.auth.currentSession!.refreshToken!;
      await SupabaseAuthRepository(client).signOut();
      expect(client.auth.currentSession, isNull);
      await expectLater(
        backendClient().auth.refreshSession(refresh),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group(
    'Stores through PostgREST (real RLS and api functions)',
    skip: backendSkip,
    () {
      test('create, replay, one store per user, update, zones', () async {
        final client = await verifiedSeller(uniqueEmail('store'));
        final repo = SupabaseStoreRepository(client);

        final before = await repo.loadContext();
        expect(before.store, isNull);
        expect(before.emailVerified, isTrue);

        const key = '6f1c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d';
        final store = await repo.createStore(
          _draft('Shilan Boutique'),
          idempotencyKey: key,
        );
        expect(store.onboardingStep, OnboardingStep.zones);
        final replay = await repo.createStore(
          _draft('Shilan Boutique'),
          idempotencyKey: key,
        );
        expect(replay.id, store.id, reason: 'same key replays the same store');
        expect(
          await _apiError(
            repo.createStore(
              _draft('Second'),
              idempotencyKey: '7a1c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
            ),
          ),
          ApiErrorCode.limitExceeded,
        );
        expect(
          await _apiError(
            repo.createStore(_draft('Changed'), idempotencyKey: key),
          ),
          ApiErrorCode.idempotencyKeyReused,
        );

        final updated = await repo.updateStore(
          store.id,
          expectedVersion: store.version,
          changes: {'name': 'Shilan Shop', 'other_payment_enabled': true},
          idempotencyKey: '8b1c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
        );
        expect(
          (updated.name, updated.otherPaymentEnabled),
          ('Shilan Shop', true),
        );
        expect(
          await _apiError(
            repo.updateStore(
              store.id,
              expectedVersion: store.version,
              changes: {'name': 'Stale'},
              idempotencyKey: '9c1c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
            ),
          ),
          ApiErrorCode.conflictVersion,
        );

        final zone = await repo.upsertZone(
          store.id,
          name: 'Erbil',
          fee: 5000,
          idempotencyKey: 'ad1c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
        );
        expect((await repo.listZones(store.id)).single.name, 'Erbil');
        await repo.deactivateZone(
          store.id,
          zoneId: zone.id,
          expectedVersion: zone.version,
        );
        expect(await repo.listZones(store.id), isEmpty);

        await repo.advanceOnboarding(store.id, OnboardingStep.done);
        // A new session (app restart) restores the same workspace.
        final again = await repo.loadContext();
        expect(again.store!.id, store.id);
        expect(again.store!.onboardingStep, OnboardingStep.done);
      });

      test(
        'tenant isolation: seller B cannot see or change seller A\'s store',
        () async {
          final a = await verifiedSeller(uniqueEmail('tenant-a'));
          final storeA = await SupabaseStoreRepository(a).createStore(
            _draft('Store A'),
            idempotencyKey: 'be1c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
          );
          final zoneA = await SupabaseStoreRepository(a).upsertZone(
            storeA.id,
            name: 'Duhok',
            fee: 4000,
            idempotencyKey: 'cf1c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
          );

          final b = await verifiedSeller(uniqueEmail('tenant-b'));
          final repoB = SupabaseStoreRepository(b);
          expect((await repoB.loadContext()).store, isNull);
          expect(
            await b.from('stores').select(),
            isEmpty,
            reason: 'RLS hides A',
          );
          expect(await b.from('delivery_zones').select(), isEmpty);
          expect(
            await repoB.listZones(storeA.id),
            isEmpty,
            reason: 'forged store id',
          );
          expect(
            await _apiError(
              repoB.updateStore(
                storeA.id,
                expectedVersion: storeA.version,
                changes: {'name': 'Taken over'},
                idempotencyKey: 'd01c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
              ),
            ),
            ApiErrorCode.notFound,
          );
          expect(
            await _apiError(
              repoB.deactivateZone(
                storeA.id,
                zoneId: zoneA.id,
                expectedVersion: zoneA.version,
              ),
            ),
            ApiErrorCode.notFound,
          );
          expect(
            await _apiError(
              repoB.advanceOnboarding(storeA.id, OnboardingStep.done),
            ),
            ApiErrorCode.notFound,
          );
          // A's store is unchanged.
          final ctxA = await SupabaseStoreRepository(a).loadContext();
          expect(
            (ctxA.store!.name, ctxA.store!.version),
            ('Store A', storeA.version),
          );
        },
      );

      test('direct table writes and unexposed schemas are refused', () async {
        final client = await verifiedSeller(uniqueEmail('direct'));
        final store = await SupabaseStoreRepository(client).createStore(
          _draft('Direct'),
          idempotencyKey: 'e11c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
        );
        await expectLater(
          client
              .from('stores')
              .update({'name': 'Direct write'})
              .eq('id', store.id),
          throwsA(isA<PostgrestException>()),
        );
        await expectLater(
          client.schema('app').from('stores').select(),
          throwsA(isA<PostgrestException>()),
          reason: 'the app schema is not exposed by PostgREST',
        );
        await expectLater(
          client
              .schema('app')
              .rpc<Object?>('is_member', params: {'p_store_id': store.id}),
          throwsA(isA<PostgrestException>()),
        );
      });

      test('anonymous callers and forged tokens are rejected', () async {
        final anon = backendClient();
        expect(
          await _apiError(callApi(anon, 'get_my_context')),
          isIn([ApiErrorCode.unauthenticated, ApiErrorCode.forbidden]),
        );
        expect(
          await _apiError(
            callApi(
              anon,
              'create_store',
              params: {
                'p_name': 'Anon',
                'p_contact_phone': '+9647501234567',
                'p_currency': 'IQD',
                'p_reply_locale': 'ckb',
                'p_business_city': 'erbil',
                'p_idempotency_key': 'f21c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
              },
            ),
          ),
          isIn([ApiErrorCode.unauthenticated, ApiErrorCode.forbidden]),
        );
        final forged = SupabaseClient(
          backendUrl,
          backendKey,
          accessToken: () async => 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4Iiwicm9sZSI6ImF1dGhlbnRpY2F0ZWQifQ.forged',
          postgrestOptions: const PostgrestClientOptions(schema: 'api'),
        );
        expect(
          await _apiError(callApi(forged, 'get_my_context')),
          ApiErrorCode.unauthenticated,
        );
      });
    },
  );

  group('Account deletion (real JWT re-authentication)', skip: backendSkip, () {
    test(
      'a fresh password sign-in can request deletion; access ends at once',
      () async {
        final email = uniqueEmail('delete');
        final client = await verifiedSeller(email);
        final repo = SupabaseStoreRepository(client);
        final store = await repo.createStore(
          _draft('Closing Shop'),
          idempotencyKey: '031c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
        );
        expect(
          await _apiError(
            repo.requestAccountDeletion(confirmStoreName: 'Wrong'),
          ),
          ApiErrorCode.validationFailed,
        );
        final when = await repo.requestAccountDeletion(
          confirmStoreName: 'Closing Shop',
        );
        expect(
          when.difference(DateTime.now()).inDays,
          inInclusiveRange(13, 14),
        );
        final ctx = await repo.loadContext();
        expect((ctx.deletionPending, ctx.store), (true, null));
        expect(await client.from('stores').select(), isEmpty);
        expect(
          await _apiError(
            repo.updateStore(
              store.id,
              expectedVersion: store.version,
              changes: {'name': 'Back'},
              idempotencyKey: '041c2b4e-8d3a-4f5b-9c7d-0e1f2a3b4c5d',
            ),
          ),
          ApiErrorCode.notFound,
        );
      },
    );
  });
}
