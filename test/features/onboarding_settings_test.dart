import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/design_system/components/app_button.dart';
import 'package:aisellia/features/auth/domain/auth_status.dart';
import 'package:aisellia/features/store/domain/store.dart';
import 'package:aisellia/features/today/presentation/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

Finder _field(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first,
  matching: find.byType(TextField),
);

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _fillStoreBasics(WidgetTester tester) async {
  await tester.enterText(_field('Store name'), '  Shilan Boutique ');
  await tester.enterText(_field('Contact phone'), '0750 123 4567');
  await _tapVisible(tester, find.text('Erbil'));
}

void main() {
  group('Store setup (AU-07..09)', () {
    testWidgets('a seller without a store lands on store setup', (
      tester,
    ) async {
      setScreen(tester);
      await tester.pumpWidget(testApp(storeBackend: FakeStoreRepository()));
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 3'), findsOneWidget);
      expect(find.text('Your store'), findsOneWidget);
      expect(find.byType(TodayScreen), findsNothing);
    });

    testWidgets('setup starts from the store name and phone given at sign-up', (
      tester,
    ) async {
      setScreen(tester);
      await tester.pumpWidget(
        testApp(
          storeBackend: FakeStoreRepository(),
          auth: FakeAuthRepository(
            initialUser: const AuthUser(
              id: '00000000-0000-4000-8000-000000000001',
              email: 'seller@example.test',
              emailVerified: true,
              storeName: 'Hevi Shop',
              phone: '+9647501112233',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hevi Shop'), findsOneWidget);
      expect(find.textContaining('750 111 2233'), findsOneWidget);
    });

    testWidgets('a new seller sees the plans before store setup', (
      tester,
    ) async {
      setScreen(tester);
      await tester.pumpWidget(
        testApp(storeBackend: FakeStoreRepository(), planChosen: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose your plan'), findsOneWidget);
      final start = find.text('Start 7-day free trial');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 3'), findsOneWidget);
    });

    testWidgets('missing fields block creation with field errors', (
      tester,
    ) async {
      setScreen(tester);
      final backend = FakeStoreRepository();
      await tester.pumpWidget(testApp(storeBackend: backend));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter your store name'), findsOneWidget);
      expect(find.text('Enter a contact phone number'), findsOneWidget);
      expect(find.text('Choose or enter your city'), findsOneWidget);
      expect(backend.calls.where((c) => c.startsWith('createStore')), isEmpty);
    });

    testWidgets('full setup: create, skip zones, finish → Today', (
      tester,
    ) async {
      setScreen(tester);
      final backend = FakeStoreRepository();
      await tester.pumpWidget(testApp(storeBackend: backend));
      await tester.pumpAndSettle();
      await _fillStoreBasics(tester);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(backend.store!.name, 'Shilan Boutique');
      expect(backend.store!.contactPhone, '+9647501234567');
      expect(backend.store!.businessCity, 'erbil');
      expect(find.text('Step 2 of 3'), findsOneWidget);

      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      expect(find.text('Step 3 of 3'), findsOneWidget);

      await tester.tap(find.text('Finish setup'));
      await tester.pumpAndSettle();
      expect(backend.store!.onboardingStep, OnboardingStep.done);
      expect(find.text('Your store is ready'), findsOneWidget);
      expect(find.byType(TodayScreen), findsOneWidget);
      // The checklist flags the skipped delivery step.
      expect(find.text('1 of 5 done'), findsOneWidget);
    });

    testWidgets('a lost response is reconciled: no error, no second store', (
      tester,
    ) async {
      setScreen(tester);
      final backend = FakeStoreRepository();
      await tester.pumpWidget(testApp(storeBackend: backend));
      await tester.pumpAndSettle();
      backend
        ..failNext = const ApiException(ApiErrorCode.timeout)
        ..applyThenFail = true;
      await _fillStoreBasics(tester);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Step 2 of 3'), findsOneWidget);
      expect(backend.calls.where((c) => c.startsWith('createStore')).length, 1);
    });

    testWidgets(
      'a failed request keeps the input and retries with the same key',
      (tester) async {
        setScreen(tester);
        final backend = FakeStoreRepository();
        await tester.pumpWidget(testApp(storeBackend: backend));
        await tester.pumpAndSettle();
        backend.failNext = const ApiException(ApiErrorCode.network);
        await _fillStoreBasics(tester);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(find.textContaining("Couldn't reach Aisellia"), findsOneWidget);
        expect(find.text('  Shilan Boutique '), findsOneWidget);
        expect(backend.store, isNull, reason: 'nothing reported as created');

        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        final keys = backend.calls
            .where((c) => c.startsWith('createStore'))
            .map((c) => c.split(':')[1])
            .toList();
        expect(keys, hasLength(2));
        expect(keys.toSet(), hasLength(1), reason: 'one intent, one key');
        expect(find.text('Step 2 of 3'), findsOneWidget);
      },
    );

    testWidgets('restarting mid-setup resumes at the saved step', (
      tester,
    ) async {
      setScreen(tester);
      await tester.pumpWidget(
        testApp(
          storeBackend: FakeStoreRepository(
            store: testStore(step: OnboardingStep.payments),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Step 3 of 3'), findsOneWidget);
    });

    testWidgets('zones accept Eastern digits and are saved before moving on', (
      tester,
    ) async {
      setScreen(tester);
      final backend = FakeStoreRepository(
        store: testStore(step: OnboardingStep.zones),
      );
      await tester.pumpWidget(testApp(storeBackend: backend));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('Erbil'));
      await tester.enterText(_field('Fee for Erbil'), '٥٬٠٠٠');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(backend.zones.single.fee, 5000);
      expect(backend.zones.single.name, 'Erbil');
      expect(find.text('Step 3 of 3'), findsOneWidget);
    });

    testWidgets('an enabled zone without a fee is not sent', (tester) async {
      setScreen(tester);
      final backend = FakeStoreRepository(
        store: testStore(step: OnboardingStep.zones),
      );
      await tester.pumpWidget(testApp(storeBackend: backend));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('Duhok'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a fee (0 for free delivery)'), findsOneWidget);
      expect(backend.zones, isEmpty);
      expect(find.text('Step 2 of 3'), findsOneWidget);
    });

    testWidgets('turning off every payment method is blocked', (tester) async {
      setScreen(tester);
      final backend = FakeStoreRepository(
        store: testStore(step: OnboardingStep.payments),
      );
      await tester.pumpWidget(testApp(storeBackend: backend));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cash on delivery'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finish setup'));
      await tester.pumpAndSettle();
      expect(find.text('Keep at least one payment method on'), findsOneWidget);
      expect(backend.store!.onboardingStep, OnboardingStep.payments);
    });
  });

  group('Store settings', () {
    Future<void> openMenuRow(WidgetTester tester, String row) async {
      await tester.tap(find.byTooltip('Store menu'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text(row));
    }

    testWidgets(
      'profile saves only the changed field and confirms after success',
      (tester) async {
        setScreen(tester);
        final backend = FakeStoreRepository(store: testStore());
        await tester.pumpWidget(testApp(storeBackend: backend));
        await tester.pumpAndSettle();
        await openMenuRow(tester, 'Store profile');
        await tester.enterText(_field('Store name'), 'Shilan Shop');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(backend.calls.last, 'updateStore:{name: Shilan Shop}');
        expect(backend.store!.version, 2);
        expect(find.text('Saved'), findsOneWidget);
      },
    );

    testWidgets(
      'a version conflict reloads and explains, without claiming success',
      (tester) async {
        setScreen(tester);
        final backend = FakeStoreRepository(store: testStore());
        await tester.pumpWidget(testApp(storeBackend: backend));
        await tester.pumpAndSettle();
        await openMenuRow(tester, 'Store profile');
        // Another device changes the store meanwhile.
        backend.store = testStore(version: 5, name: 'Changed elsewhere');
        await tester.enterText(_field('Store name'), 'Mine');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('changed on another device'),
          findsOneWidget,
        );
        expect(find.text('Saved'), findsNothing);
        expect(find.text('Changed elsewhere'), findsOneWidget);
      },
    );

    testWidgets('delivery zones: list, add through the sheet, remove', (
      tester,
    ) async {
      setScreen(tester);
      final backend = FakeStoreRepository(store: testStore());
      await tester.pumpWidget(testApp(storeBackend: backend));
      await tester.pumpAndSettle();
      await openMenuRow(tester, 'Delivery zones');
      expect(find.text('No delivery zones yet'), findsOneWidget);

      await tester.tap(find.text('Add zone').last);
      await tester.pumpAndSettle();
      await tester.enterText(_field('Area name'), 'Halabja');
      await tester.pump(); // the fee label follows the zone name
      await tester.enterText(_field('Fee for Halabja'), '7000');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(backend.zones.single.name, 'Halabja');
      expect(find.text('Zone saved'), findsOneWidget);

      await tester.tap(find.text('Halabja'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove zone'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();
      expect(backend.zones, isEmpty);
      expect(find.text('Zone removed'), findsOneWidget);
    });

    testWidgets('account shows the email and can sign out everywhere', (
      tester,
    ) async {
      setScreen(tester);
      final auth = FakeAuthRepository(initialUser: testUser);
      await tester.pumpWidget(testApp(auth: auth));
      await tester.pumpAndSettle();
      await openMenuRow(tester, 'Account');
      expect(find.text(testUser.email), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      await tester.tap(find.text('Sign out of all devices'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out').last);
      await tester.pumpAndSettle();
      expect(auth.calls, contains('signOut:global'));
      expect(find.text('I have an account'), findsOneWidget);
    });
  });

  group('Delete account (ST-08)', () {
    Future<(FakeAuthRepository, FakeStoreRepository)> openDelete(
      WidgetTester tester,
    ) async {
      setScreen(tester);
      final auth = FakeAuthRepository(initialUser: testUser)
        ..accounts[testUser.email] = 'correct-horse';
      final backend = FakeStoreRepository(store: testStore());
      await tester.pumpWidget(testApp(auth: auth, storeBackend: backend));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Store menu'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('Account'));
      await _tapVisible(tester, find.text('Delete account'));
      return (auth, backend);
    }

    Finder deleteButton() => find.widgetWithText(AppButton, 'Delete account');

    testWidgets('requires the password and the exact store name', (
      tester,
    ) async {
      final (_, backend) = await openDelete(tester);
      expect(find.textContaining('This cannot be undone'), findsOneWidget);
      expect(find.textContaining('14 days'), findsOneWidget);
      expect(tester.widget<AppButton>(deleteButton()).onPressed, isNull);
      await tester.enterText(_field('Password'), 'correct-horse');
      await tester.enterText(find.byType(TextField).last, 'Shilan');
      await tester.pump();
      expect(tester.widget<AppButton>(deleteButton()).onPressed, isNull);
      expect(
        backend.calls.where((c) => c.startsWith('requestDeletion')),
        isEmpty,
      );
    });

    testWidgets('a wrong password deletes nothing and says so', (tester) async {
      final (_, backend) = await openDelete(tester);
      await tester.enterText(_field('Password'), 'wrong-password');
      await tester.enterText(find.byType(TextField).last, 'Shilan Boutique');
      await tester.pump();
      await tester.tap(deleteButton());
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing was deleted.'), findsOneWidget);
      expect(
        backend.calls.where((c) => c.startsWith('requestDeletion')),
        isEmpty,
      );
      expect(backend.store, isNotNull);
    });

    testWidgets('success closes the account and only sign-out remains', (
      tester,
    ) async {
      final (auth, backend) = await openDelete(tester);
      await tester.enterText(_field('Password'), 'correct-horse');
      await tester.enterText(find.byType(TextField).last, 'Shilan Boutique');
      await tester.pump();
      await tester.tap(deleteButton());
      await tester.pumpAndSettle();
      expect(
        auth.calls,
        contains('signIn:${testUser.email}'),
        reason: 're-authenticated',
      );
      expect(backend.calls, contains('requestDeletion:Shilan Boutique'));
      expect(find.text('Your account is being deleted'), findsOneWidget);
      expect(find.textContaining('29 October 2026'), findsOneWidget);
      expect(find.byType(TodayScreen), findsNothing);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('I have an account'), findsOneWidget);
    });
  });
}
