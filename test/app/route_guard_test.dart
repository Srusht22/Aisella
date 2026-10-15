import 'package:aisellia/app/route_guard.dart';
import 'package:aisellia/features/auth/domain/auth_status.dart';
import 'package:aisellia/features/store/domain/store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

const _protected = [
  Routes.today,
  Routes.inbox,
  Routes.orders,
  Routes.draftPreview,
  Routes.products,
  Routes.store,
  Routes.storeProfile,
  Routes.storeZones,
  Routes.storePayments,
  Routes.storeAccount,
  Routes.storeLanguage,
  '/later/customers',
  '/no-such-route',
];

const _all = [
  ..._protected,
  Routes.language,
  Routes.starting,
  Routes.unavailable,
  Routes.welcome,
  Routes.signIn,
  Routes.signUp,
  Routes.verifyEmail,
  Routes.forgotPassword,
  Routes.terms,
  Routes.newPassword,
  Routes.setupStore,
  Routes.setupZones,
  Routes.setupPayments,
];

final _states = <String, RouteGate>{
  'language not chosen': const RouteGate(
    languageChosen: false,
    auth: SignedIn(testUser),
    workspace: GateReady(),
  ),
  'initializing': const RouteGate(
    languageChosen: true,
    auth: AuthInitializing(),
  ),
  'signed out': const RouteGate(languageChosen: true, auth: SignedOut()),
  'session expired': const RouteGate(
    languageChosen: true,
    auth: SignedOut(SignedOutReason.sessionExpired),
  ),
  'password recovery': const RouteGate(
    languageChosen: true,
    auth: PasswordRecovery(testUser),
  ),
  for (final (name, gate) in const [
    ('loading', GateLoading()),
    ('unavailable', GateUnavailable()),
    ('deletion pending', GateDeletionPending()),
    ('no store', GateNoStore()),
    ('onboarding zones', GateOnboarding(OnboardingStep.zones)),
    ('onboarding payments', GateOnboarding(OnboardingStep.payments)),
    ('ready', GateReady()),
  ])
    'signed in, $name': RouteGate(
      languageChosen: true,
      auth: const SignedIn(testUser),
      workspace: gate,
    ),
};

void main() {
  group('guardRedirect', () {
    for (final MapEntry(key: name, value: gate) in _states.entries) {
      test('$name: every route lands on an allowed, stable home', () {
        final home = homeFor(gate);
        expect(isAllowed(home, gate), isTrue, reason: 'home $home allowed');
        expect(guardRedirect(home, gate), isNull, reason: 'no loop at $home');
        for (final path in _all) {
          final target = guardRedirect(path, gate) ?? path;
          expect(
            guardRedirect(target, gate),
            isNull,
            reason: '$path → $target must be final',
          );
        }
      });
    }

    test(
      'nothing protected is reachable unless signed in with a ready store',
      () {
        for (final MapEntry(key: name, value: gate) in _states.entries) {
          if (name == 'signed in, ready') continue;
          for (final path in _protected) {
            expect(isAllowed(path, gate), isFalse, reason: '$name: $path');
          }
        }
      },
    );

    test('signed-out sellers see only public routes', () {
      const gate = RouteGate(languageChosen: true, auth: SignedOut());
      expect(guardRedirect(Routes.today, gate), Routes.welcome);
      expect(guardRedirect(Routes.setupStore, gate), Routes.welcome);
      expect(guardRedirect(Routes.signUp, gate), isNull);
    });

    test('an expired session goes to sign-in, not welcome', () {
      const gate = RouteGate(
        languageChosen: true,
        auth: SignedOut(SignedOutReason.sessionExpired),
      );
      expect(guardRedirect(Routes.today, gate), Routes.signIn);
    });

    test('setup resumes at the first incomplete step', () {
      RouteGate at(WorkspaceGate w) => RouteGate(
        languageChosen: true,
        auth: const SignedIn(testUser),
        workspace: w,
      );
      expect(homeFor(at(const GateNoStore())), Routes.setupStore);
      expect(
        homeFor(at(const GateOnboarding(OnboardingStep.zones))),
        Routes.setupZones,
      );
      expect(
        homeFor(at(const GateOnboarding(OnboardingStep.payments))),
        Routes.setupPayments,
      );
      // Back from payments to zones is allowed; creating a second store is not.
      expect(
        isAllowed(
          Routes.setupZones,
          at(const GateOnboarding(OnboardingStep.payments)),
        ),
        isTrue,
      );
      expect(
        isAllowed(
          Routes.setupStore,
          at(const GateOnboarding(OnboardingStep.zones)),
        ),
        isFalse,
      );
    });

    test('a ready seller cannot reopen sign-in or setup screens', () {
      const gate = RouteGate(
        languageChosen: true,
        auth: SignedIn(testUser),
        workspace: GateReady(),
      );
      for (final path in [Routes.signIn, Routes.welcome, Routes.setupStore]) {
        expect(guardRedirect(path, gate), Routes.today);
      }
    });
  });

  group('workspaceGateFor', () {
    AccountContext ctx({String userId = '', Store? store}) => AccountContext(
      userId: userId.isEmpty ? testUser.id : userId,
      email: testUser.email,
      emailVerified: true,
      deletionPending: false,
      store: store,
    );

    test('maps the server context to a gate', () {
      expect(
        workspaceGateFor(AsyncData(ctx()), testUser.id),
        isA<GateNoStore>(),
      );
      expect(
        workspaceGateFor(AsyncData(ctx(store: testStore())), testUser.id),
        isA<GateReady>(),
      );
      expect(
        workspaceGateFor(
          AsyncData(ctx(store: testStore(step: OnboardingStep.payments))),
          testUser.id,
        ),
        isA<GateOnboarding>(),
      );
    });

    test('another user\'s workspace is never used, even while reloading', () {
      final other = AsyncData<AccountContext?>(
        ctx(userId: 'someone-else', store: testStore()),
      );
      expect(workspaceGateFor(other, testUser.id), isA<GateLoading>());
    });

    test('errors are unavailable; loading without data is loading', () {
      expect(
        workspaceGateFor(
          AsyncError<AccountContext?>(Exception(), StackTrace.empty),
          testUser.id,
        ),
        isA<GateUnavailable>(),
      );
      expect(
        workspaceGateFor(const AsyncLoading(), testUser.id),
        isA<GateLoading>(),
      );
    });
  });
}
