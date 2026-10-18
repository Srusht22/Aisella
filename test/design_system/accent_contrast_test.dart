import 'package:aisellia/core/settings/app_settings.dart';
import 'package:aisellia/design_system/theme/accents.dart';
import 'package:aisellia/design_system/tokens/tokens.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('the classic theme is the original palette', () {
    expect(
      accentPalette(AppAccent.ledger, Brightness.light),
      same(AiselliaPalette.light),
    );
    expect(
      accentPalette(AppAccent.ledger, Brightness.dark),
      same(AiselliaPalette.dark),
    );
  });

  for (final accent in AppAccent.values) {
    for (final b in Brightness.values) {
      test('${accent.name} ${b.name} keeps WCAG contrast', () {
        final p = accentPalette(accent, b);
        // Text on the brand fill (buttons) and brand text (links).
        expect(_contrast(p.textOnBrand, p.brandPrimary), greaterThan(4.5));
        expect(_contrast(p.textBrand, p.bgCanvas), greaterThan(4.5));
        expect(_contrast(p.textBrand, p.bgSurface), greaterThan(4.5));
        expect(_contrast(p.textBrand, p.bgBrandWeak), greaterThan(4.5));
        // Body text on the tinted neutrals.
        expect(_contrast(p.textPrimary, p.bgCanvas), greaterThan(7));
        expect(_contrast(p.textSecondary, p.bgSurface), greaterThan(4.5));
        // Focus ring and controls are visible.
        expect(_contrast(p.borderFocus, p.bgCanvas), greaterThan(3));
      });
    }
  }
}
