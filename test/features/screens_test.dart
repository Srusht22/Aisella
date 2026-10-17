import 'dart:io';

import 'package:aisellia/features/orders/presentation/approve_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

Future<void> _openDraftPreview(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Orders'),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Preview the draft review screen'));
  await tester.pumpAndSettle();
}

void main() {
  group('Today', () {
    testWidgets('sample data is always labelled', (tester) async {
      setScreen(tester);
      await tester.pumpWidget(testApp());
      await tester.pumpAndSettle();
      expect(find.text('Sample data'), findsOneWidget);
      expect(find.text('Needs approval'), findsOneWidget);
    });

    testWidgets(
      'without sample data, Today shows the checklist and no fake counts',
      (tester) async {
        setScreen(tester);
        await tester.pumpWidget(testApp(sampleData: false));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('arrive in a later release'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            RegExp('set up your store', caseSensitive: false),
          ),
          findsOneWidget,
        );
        expect(find.text('2 of 5 done'), findsOneWidget);
        expect(find.text('Needs approval'), findsNothing);
        expect(find.text('Sample data'), findsNothing);
      },
    );
  });

  group('Draft review preview (OR-02/OR-03)', () {
    testWidgets(
      'Approve is disabled until the inferred quantity is confirmed',
      (tester) async {
        setScreen(tester);
        await tester.pumpWidget(testApp());
        await tester.pumpAndSettle();
        await _openDraftPreview(tester);

        expect(
          find.text('Confirm the quantity to enable approval'),
          findsOneWidget,
        );
        await tester.tap(find.text('Approve order'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Approve order #'),
          findsNothing,
          reason: 'sheet must not open',
        );

        await tester.ensureVisible(find.text('Confirm'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(
          find.text('Confirm the quantity to enable approval'),
          findsNothing,
        );
        expect(find.text('Edited by you'), findsOneWidget);
      },
    );

    testWidgets('the reason line scrolls the quantity control into view', (
      tester,
    ) async {
      setScreen(tester);
      await tester.pumpWidget(testApp());
      await tester.pumpAndSettle();
      await _openDraftPreview(tester);
      expect(find.text('Confirm').hitTestable(), findsNothing);
      await tester.tap(find.text('Confirm the quantity to enable approval'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm').hitTestable(), findsOneWidget);
    });

    testWidgets('confirmation is guarded and never reports a fake approval', (
      tester,
    ) async {
      setScreen(tester);
      await tester.pumpWidget(testApp());
      await tester.pumpAndSettle();
      await _openDraftPreview(tester);
      await tester.ensureVisible(find.text('Confirm'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve order'));
      await tester.pump(const Duration(milliseconds: 100));

      // Within the input guard the confirm button is disabled.
      await tester.tap(find.text('Confirm approval'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('Not connected yet'), findsNothing);

      await tester.pump(kApproveInputGuard);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm approval'));
      await tester.pumpAndSettle();
      expect(find.text('Not connected yet'), findsOneWidget);
      expect(find.textContaining('Nothing was approved'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      // The draft is unchanged: still pencil, still "Needs approval".
      expect(find.text('Draft — not confirmed'), findsOneWidget);
      expect(find.text('Needs approval'), findsOneWidget);
      expect(find.text('Approved'), findsNothing);
    });
  });

  test('sources contain no literal bidi control characters', () {
    final bad = RegExp('[\u202a-\u202e\u2066-\u2069]');
    for (final dir in ['lib', 'test', 'tool']) {
      for (final f
          in Directory(dir)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        expect(bad.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
      }
    }
  });
}
