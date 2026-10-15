import 'package:aisellia/app/localization_setup.dart';
import 'package:aisellia/design_system/components/app_button.dart';
import 'package:aisellia/design_system/components/overlays.dart';
import 'package:aisellia/design_system/components/pencil.dart';
import 'package:aisellia/design_system/components/status.dart';
import 'package:aisellia/design_system/motion/motion.dart';
import 'package:aisellia/design_system/motion/primitives.dart';
import 'package:aisellia/design_system/theme/app_theme.dart';
import 'package:aisellia/design_system/tokens/tokens.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(
  Widget child, {
  bool reduce = false,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: appSupportedLocales,
  localizationsDelegates: appLocalizationsDelegates,
  theme: buildAppTheme(brightness: brightness, locale: const Locale('en')),
  home: MotionScope(
    reduce: reduce,
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('AppButton', () {
    testWidgets('fires when enabled', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(AppButton(label: 'Save', onPressed: () => taps++)),
      );
      await tester.tap(find.text('Save'));
      expect(taps, 1);
    });

    testWidgets('disabled button ignores taps and reports disabled', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const AppButton(label: 'Approve order', onPressed: null)),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Approve order')),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );
    });

    testWidgets('loading shows progress label, keeps width, ignores taps', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(AppButton(label: 'Save', onPressed: () => taps++)),
      );
      final idleWidth = tester.getSize(find.byType(AppButton)).width;
      await tester.pumpWidget(
        _host(
          AppButton(
            label: 'Save',
            loadingLabel: 'Saving…',
            loading: true,
            onPressed: () => taps++,
          ),
        ),
      );
      expect(find.text('Saving…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.getSize(find.byType(AppButton)).width,
        greaterThanOrEqualTo(idleWidth),
      );
      await tester.tap(find.text('Saving…'), warnIfMissed: false);
      expect(taps, 0);
    });

    testWidgets('meets the 48 dp touch target', (tester) async {
      await tester.pumpWidget(
        _host(
          AppButton(
            label: 'OK',
            variant: AppButtonVariant.tertiary,
            onPressed: () {},
          ),
        ),
      );
      final size = tester.getSize(find.byType(AppButton));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });
  });

  testWidgets('status badges always carry icon and text', (tester) async {
    await tester.pumpWidget(
      _host(
        const StatusBadge(
          label: 'Delivered',
          icon: Icons.check,
          tone: Tone.success,
        ),
      ),
    );
    expect(find.text('Delivered'), findsOneWidget);
    expect(find.byType(Icon), findsOneWidget);
  });

  testWidgets('theme exposes palette and typography in light and dark', (
    tester,
  ) async {
    for (final b in Brightness.values) {
      final theme = buildAppTheme(brightness: b, locale: const Locale('ckb'));
      expect(theme.extension<AiselliaPalette>(), isNotNull);
      expect(
        theme.scaffoldBackgroundColor,
        b == Brightness.dark
            ? AiselliaPalette.dark.bgCanvas
            : AiselliaPalette.light.bgCanvas,
      );
    }
  });

  group('Motion', () {
    testWidgets('reduced motion comes from the app setting or the OS', (
      tester,
    ) async {
      late bool reduced;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (c) {
              reduced = Motion.reduced(c);
              return const SizedBox();
            },
          ),
          reduce: true,
        ),
      );
      expect(reduced, isTrue);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (c) {
              reduced = Motion.reduced(c);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(reduced, isFalse);
    });

    testWidgets('NumberRoll animates normally and is instant when reduced', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const NumberRoll(value: 4, text: '4')));
      await tester.pumpWidget(_host(const NumberRoll(value: 2, text: '2')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('4'),
        findsOneWidget,
        reason: 'old value still animating out',
      );
      await tester.pumpAndSettle();
      expect(find.text('4'), findsNothing);

      await tester.pumpWidget(
        _host(const NumberRoll(value: 4, text: '4'), reduce: true),
      );
      await tester.pumpWidget(
        _host(const NumberRoll(value: 2, text: '2'), reduce: true),
      );
      await tester.pump();
      expect(find.text('4'), findsNothing);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets(
      'pencil stays dashed until explicitly settled; interruption is safe',
      (tester) async {
        await tester.pumpWidget(_host(const PencilBox(child: Text('Draft'))));
        await tester.pumpAndSettle();
        var painter =
            tester
                    .widget<CustomPaint>(
                      find
                          .descendant(
                            of: find.byType(PencilBox),
                            matching: find.byType(CustomPaint),
                          )
                          .first,
                    )
                    .painter!
                as PencilBorderPainter;
        expect(
          painter.gap,
          greaterThan(0),
          reason: 'drafts must look provisional',
        );

        await tester.pumpWidget(
          _host(const PencilBox(settled: true, child: Text('Draft'))),
        );
        await tester.pump(const Duration(milliseconds: 50));
        // Interrupt mid-animation by flipping back: must return to dashed.
        await tester.pumpWidget(_host(const PencilBox(child: Text('Draft'))));
        await tester.pumpAndSettle();
        painter =
            tester
                    .widget<CustomPaint>(
                      find
                          .descendant(
                            of: find.byType(PencilBox),
                            matching: find.byType(CustomPaint),
                          )
                          .first,
                    )
                    .painter!
                as PencilBorderPainter;
        expect(painter.gap, closeTo(Strokes.pencilGap, 0.001));
      },
    );
  });

  group('Overlays', () {
    testWidgets('discard dialog defaults to keeping edits', (tester) async {
      bool? result;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (c) => TextButton(
              onPressed: () async => result = await confirmDiscard(c),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets('sticky action bar stacks buttons at large text', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        _host(
          StickyActionBar(
            secondary: AppButton(
              label: 'Reject',
              variant: AppButtonVariant.dangerOutline,
              onPressed: () {},
            ),
            primary: AppButton(label: 'Approve order', onPressed: () {}),
          ),
        ),
      );
      final reject = tester.getTopLeft(find.text('Reject'));
      final approve = tester.getTopLeft(find.text('Approve order'));
      expect(
        reject.dy,
        greaterThan(approve.dy),
        reason: 'stacked: primary on top',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
