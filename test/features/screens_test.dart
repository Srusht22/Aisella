import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

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
      'without sample data, Today shows the checklist and real (empty) counts',
      (tester) async {
        setScreen(tester);
        await tester.pumpWidget(testApp(sampleData: false));
        await tester.pumpAndSettle();
        // No orders yet: nothing needs attention, nothing sold today.
        expect(find.textContaining('All caught up'), findsOneWidget);
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
