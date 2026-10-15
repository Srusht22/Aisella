import 'package:aisellia/app/localization_setup.dart';
import 'package:aisellia/design_system/components/inputs.dart';
import 'package:aisellia/design_system/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the visible label is the text field\'s accessible name', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        theme: buildAppTheme(
          brightness: Brightness.light,
          locale: const Locale('en'),
        ),
        home: Scaffold(
          body: AppTextField(
            label: 'Email',
            suffix: IconButton(
              onPressed: () {},
              icon: const Icon(Icons.abc),
              tooltip: 'Show',
            ),
          ),
        ),
      ),
    );
    final node = tester.getSemantics(find.byType(TextField));
    expect(node.label, contains('Email'));
    expect(node.flagsCollection.isTextField, isTrue);
    // The visible label is not announced a second time as plain text.
    expect(find.bySemanticsLabel('Email'), findsOneWidget);
    handle.dispose();
  });
}
