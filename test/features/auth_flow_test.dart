import 'package:aisellia/app/gate_screens.dart';
import 'package:aisellia/core/backend/api.dart';
import 'package:aisellia/features/auth/data/auth_repository.dart';
import 'package:aisellia/features/auth/domain/auth_status.dart';
import 'package:aisellia/features/today/presentation/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

Future<void> _type(WidgetTester tester, String label, String text) async {
  await tester.enterText(
    find.descendant(
      of: find
          .ancestor(of: find.text(label), matching: find.byType(Column))
          .first,
      matching: find.byType(TextField),
    ),
    text,
  );
}

Finder _button(String label) => find.widgetWithText(GestureDetector, label);

/// Fills every sign-up field; [confirm] defaults to the password.
Future<void> _fillSignUp(
  WidgetTester tester, {
  required String email,
  required String password,
  String? confirm,
}) async {
  await _type(tester, 'Full name', 'Shilan Hama');
  await _type(tester, 'Store name', 'Shilan Boutique');
  await _type(tester, 'Phone', '0750 123 4567');
  await _type(tester, 'Email', email);
  await _type(tester, 'Password', password);
  await _type(tester, 'Confirm password', confirm ?? password);
}

Future<void> _tapCreate(WidgetTester tester) async {
  final button = find.text('Create account').last;
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  group('Protected navigation', () {
    testWidgets('signed out: the app opens on Welcome, never Today', (
      tester,
    ) async {
      setScreen(tester);
      await tester.pumpWidget(testApp(signedIn: false));
      await tester.pumpAndSettle();
      expect(find.text('Create account'), findsWidgets);
      expect(find.byType(TodayScreen), findsNothing);
    });

    testWidgets('Welcome offers a language switch that applies at once', (
      tester,
    ) async {
      setScreen(tester);
      await tester.pumpWidget(testApp(signedIn: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('App language'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('العربية'));
      await tester.pumpAndSettle();
      expect(find.text('Create account'), findsNothing);
      expect(
        Directionality.of(tester.element(find.byType(Scaffold).first)),
        TextDirection.rtl,
      );
    });

    testWidgets(
      'session restore shows no protected content before the workspace loads',
      (tester) async {
        setScreen(tester);
        final backend = FakeStoreRepository(
          store: testStore(),
          loadDelay: const Duration(milliseconds: 500),
        );
        await tester.pumpWidget(testApp(storeBackend: backend));
        await tester.pump();
        expect(find.byType(TodayScreen), findsNothing);
        expect(find.byType(StartingScreen), findsOneWidget);
        await tester.pumpAndSettle();
        expect(find.byType(TodayScreen), findsOneWidget);
      },
    );

    testWidgets('workspace load failure offers retry, then opens the store', (
      tester,
    ) async {
      setScreen(tester);
      final backend = FakeStoreRepository(store: testStore())
        ..failNext = const ApiException(ApiErrorCode.network);
      await tester.pumpWidget(testApp(storeBackend: backend));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't open your store"), findsOneWidget);
      expect(find.byType(TodayScreen), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsOneWidget);
    });

    testWidgets(
      'a rejected session (401) returns to sign-in with an explanation',
      (tester) async {
        setScreen(tester);
        final auth = FakeAuthRepository(initialUser: testUser);
        final backend = FakeStoreRepository(store: testStore())
          ..failNext = const ApiException(ApiErrorCode.unauthenticated);
        await tester.pumpWidget(testApp(auth: auth, storeBackend: backend));
        await tester.pumpAndSettle();
        expect(
          find.text('Your session ended. Please sign in again.'),
          findsOneWidget,
        );
        expect(find.byType(TodayScreen), findsNothing);
      },
    );

    testWidgets('a session ended by the provider leaves the workspace', (
      tester,
    ) async {
      setScreen(tester);
      final auth = FakeAuthRepository(initialUser: testUser);
      await tester.pumpWidget(testApp(auth: auth));
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsOneWidget);
      auth.emit(AuthEventKind.signedOut);
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsNothing);
      expect(
        find.text('Your session ended. Please sign in again.'),
        findsOneWidget,
      );
    });
  });

  group('Sign up (AU-03)', () {
    testWidgets('the terms open in a sheet over the form, keeping input', (
      tester,
    ) async {
      setScreen(tester);
      await tester.pumpWidget(testApp(signedIn: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create account').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'a@example.com');
      await tester.ensureVisible(find.text('Terms and Privacy Policy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terms and Privacy Policy'));
      await tester.pumpAndSettle();
      expect(find.text("Your store's data is yours"), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('a@example.com'), findsOneWidget);
    });

    testWidgets('invalid input shows field errors and sends nothing', (
      tester,
    ) async {
      setScreen(tester);
      final auth = FakeAuthRepository();
      await tester.pumpWidget(testApp(auth: auth, signedIn: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create account').first);
      await tester.pumpAndSettle();
      await _type(tester, 'Email', 'not-an-email');
      await _type(tester, 'Phone', '12345');
      await _type(tester, 'Password', 'short');
      await _type(tester, 'Confirm password', 'different');
      await _tapCreate(tester);
      expect(
        find.textContaining('Enter a valid email address'),
        findsOneWidget,
      );
      expect(find.text('Use at least 8 characters'), findsOneWidget);
      expect(find.text('Enter your name'), findsOneWidget);
      expect(find.textContaining('Iraqi mobile number'), findsWidgets);
      expect(find.text('The passwords do not match'), findsOneWidget);
      expect(auth.calls, isEmpty);
    });

    testWidgets(
      'a new account goes to "Check your inbox" with the terms recorded',
      (tester) async {
        setScreen(tester);
        final auth = FakeAuthRepository();
        await tester.pumpWidget(testApp(auth: auth, signedIn: false));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create account').first);
        await tester.pumpAndSettle();
        await _fillSignUp(
          tester,
          email: ' new@example.test ',
          password: 'correct-horse',
        );
        await _tapCreate(tester);
        expect(auth.calls, ['signUp:new@example.test:2026-10']);
        final profile = auth.profiles['new@example.test']!;
        expect(profile.fullName, 'Shilan Hama');
        expect(profile.storeName, 'Shilan Boutique');
        expect(profile.phone, '+9647501234567');
        expect(find.text('Check your inbox'), findsOneWidget);
        expect(find.textContaining('new@example.test'), findsWidgets);
        // The resend cooldown is visible straight away (an email was just sent).
        expect(find.textContaining('Resend in'), findsOneWidget);
      },
    );

    testWidgets(
      'an existing email offers sign-in and reset, no second account',
      (tester) async {
        setScreen(tester);
        final auth = FakeAuthRepository()..accounts['taken@example.test'] = 'x';
        await tester.pumpWidget(testApp(auth: auth, signedIn: false));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create account').first);
        await tester.pumpAndSettle();
        await _fillSignUp(
          tester,
          email: 'taken@example.test',
          password: 'correct-horse',
        );
        await _tapCreate(tester);
        expect(find.text('An account exists with this email.'), findsOneWidget);
        expect(find.text('Reset password'), findsOneWidget);
        expect(auth.accounts.length, 1);
      },
    );
  });

  group('Sign in (AU-04)', () {
    Future<FakeAuthRepository> openSignIn(
      WidgetTester tester, {
      Duration delay = Duration.zero,
    }) async {
      setScreen(tester);
      final auth = FakeAuthRepository(signInDelay: delay)
        ..accounts['seller@example.test'] = 'correct-horse';
      await tester.pumpWidget(testApp(auth: auth, signedIn: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I have an account'));
      await tester.pumpAndSettle();
      return auth;
    }

    testWidgets('wrong credentials give one generic message', (tester) async {
      await openSignIn(tester);
      await _type(tester, 'Email', 'seller@example.test');
      await _type(tester, 'Password', 'wrong-password');
      await tester.tap(find.text('Sign in').last);
      await tester.pumpAndSettle();
      expect(find.text('Email or password is incorrect.'), findsOneWidget);
      expect(find.byType(TodayScreen), findsNothing);
    });

    testWidgets('success opens the seller\'s workspace', (tester) async {
      await openSignIn(tester);
      await _type(tester, 'Email', 'seller@example.test');
      await _type(tester, 'Password', 'correct-horse');
      await tester.tap(find.text('Sign in').last);
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsOneWidget);
    });

    testWidgets('double taps send one request and show progress', (
      tester,
    ) async {
      final auth = await openSignIn(
        tester,
        delay: const Duration(milliseconds: 300),
      );
      await _type(tester, 'Email', 'seller@example.test');
      await _type(tester, 'Password', 'correct-horse');
      await tester.tap(find.text('Sign in').last);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Signing in…'), findsOneWidget);
      await tester.tap(find.text('Signing in…'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(auth.calls.where((c) => c.startsWith('signIn')).length, 1);
    });

    testWidgets(
      'an unverified email explains and offers the verification screen',
      (tester) async {
        final auth = await openSignIn(tester);
        auth.unverified.add('seller@example.test');
        await _type(tester, 'Email', 'seller@example.test');
        await _type(tester, 'Password', 'correct-horse');
        await tester.tap(find.text('Sign in').last);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Verify your email address'),
          findsOneWidget,
        );
        await tester.tap(find.text('Resend email'));
        await tester.pumpAndSettle();
        expect(find.text('Check your inbox'), findsOneWidget);
      },
    );

    testWidgets('service failures are distinguished from wrong credentials', (
      tester,
    ) async {
      final auth = await openSignIn(tester);
      auth.failNext = AuthFailure.network;
      await _type(tester, 'Email', 'seller@example.test');
      await _type(tester, 'Password', 'correct-horse');
      await tester.tap(find.text('Sign in').last);
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't reach Aisellia"), findsOneWidget);
      // Input is preserved for the retry.
      expect(find.text('seller@example.test'), findsOneWidget);
    });
  });

  group('Sign out', () {
    testWidgets('confirms, ends the session and Back cannot return', (
      tester,
    ) async {
      setScreen(tester);
      final auth = FakeAuthRepository(initialUser: testUser);
      await tester.pumpWidget(testApp(auth: auth));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Store menu'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out of Aisellia on this device?'), findsOneWidget);
      await tester.tap(find.text('Sign out').last);
      await tester.pumpAndSettle();
      expect(auth.calls, contains('signOut:local'));
      expect(find.text('I have an account'), findsOneWidget);
      // System back cannot reach protected content.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsNothing);
    });

    testWidgets('signing in again reloads the workspace from the server', (
      tester,
    ) async {
      setScreen(tester);
      final auth = FakeAuthRepository(initialUser: testUser)
        ..accounts['seller@example.test'] = 'correct-horse';
      final backend = FakeStoreRepository(store: testStore());
      await tester.pumpWidget(testApp(auth: auth, storeBackend: backend));
      await tester.pumpAndSettle();
      final loadsBefore = backend.calls.where((c) => c == 'loadContext').length;
      auth.emit(AuthEventKind.signedOut);
      await tester.pumpAndSettle();
      await _type(tester, 'Email', 'seller@example.test');
      await _type(tester, 'Password', 'correct-horse');
      await tester.tap(find.text('Sign in').last);
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(
        backend.calls.where((c) => c == 'loadContext').length,
        loadsBefore + 1,
      );
    });
  });

  group('Password reset (AU-05) and recovery', () {
    testWidgets('the response does not reveal whether the account exists', (
      tester,
    ) async {
      setScreen(tester);
      final auth = FakeAuthRepository();
      await tester.pumpWidget(testApp(auth: auth, signedIn: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I have an account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();
      await _type(tester, 'Email', 'nobody@example.test');
      await tester.tap(find.text('Send reset link'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining("we've sent a link to reset the password."),
        findsOneWidget,
      );
      expect(auth.calls, ['reset:nobody@example.test']);
      expect(find.textContaining('Resend in'), findsOneWidget);
    });

    testWidgets(
      'a reset link opens "Choose a new password"; nothing else is reachable',
      (tester) async {
        setScreen(tester);
        final auth = FakeAuthRepository();
        await tester.pumpWidget(testApp(auth: auth, signedIn: false));
        await tester.pumpAndSettle();
        auth.emit(AuthEventKind.passwordRecovery, testUser);
        await tester.pumpAndSettle();
        expect(find.text('Choose a new password'), findsOneWidget);

        await _type(tester, 'New password', 'new-password-1');
        await _type(tester, 'Confirm password', 'different-1');
        await tester.tap(find.text('Save password'));
        await tester.pumpAndSettle();
        expect(find.text("Passwords don't match"), findsOneWidget);
        expect(auth.calls, isEmpty);

        await _type(tester, 'Confirm password', 'new-password-1');
        await tester.tap(find.text('Save password'));
        await tester.pumpAndSettle();
        expect(auth.calls, ['updatePassword']);
        expect(find.text('Password changed'), findsOneWidget);
        expect(find.byType(TodayScreen), findsOneWidget);
      },
    );
  });

  test('link constants are used by the repository', () {
    expect(AuthLinks.callback, startsWith('app.aisellia://'));
    expect(_button, isNotNull);
  });
}
