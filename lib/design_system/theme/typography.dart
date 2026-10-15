import 'package:flutter/material.dart' show ThemeExtension;
import 'package:flutter/widgets.dart';

import '../tokens/tokens.g.dart';

/// Script family of the active locale. Sorani (and later Arabic) use the
/// Arabic-script type scale: one step larger, taller lines, no tracking,
/// no uppercase (Phase 2 §3.2).
enum ScriptKind { latin, arabic }

ScriptKind scriptFor(Locale locale) =>
    const {'ckb', 'ar', 'fa'}.contains(locale.languageCode)
    ? ScriptKind.arabic
    : ScriptKind.latin;

/// Inter first (Latin and Western digits), Vazirmatn NL second (Arabic
/// script). The same stack is used in every locale so mixed content renders
/// consistently (Phase 2 §3.1).
const kFontFamily = 'Inter';
const kFontFallback = ['VazirmatnNL'];

/// The Phase 2 type scale for one script, resolved to [TextStyle]s.
/// Colours are applied at the use site via the palette.
@immutable
final class AppTypography extends ThemeExtension<AppTypography> {
  const AppTypography({
    required this.script,
    required this.titleLarge,
    required this.title,
    required this.heading,
    required this.overline,
    required this.bodyLarge,
    required this.body,
    required this.bodyStrong,
    required this.label,
    required this.caption,
    required this.button,
    required this.numericBody,
    required this.numericTotal,
    required this.numericMetric,
  });

  factory AppTypography.forScript(ScriptKind script) {
    final ckb = script == ScriptKind.arabic;
    TextStyle s(TypeSpec en, TypeSpec ar) => _style(ckb ? ar : en);
    return AppTypography(
      script: script,
      titleLarge: s(
        TypeScaleTokens.titleLargeEn,
        TypeScaleTokens.titleLargeCkb,
      ),
      title: s(TypeScaleTokens.titleEn, TypeScaleTokens.titleCkb),
      heading: s(TypeScaleTokens.headingEn, TypeScaleTokens.headingCkb),
      overline: s(TypeScaleTokens.overlineEn, TypeScaleTokens.overlineCkb),
      bodyLarge: s(TypeScaleTokens.bodyLargeEn, TypeScaleTokens.bodyLargeCkb),
      body: s(TypeScaleTokens.bodyEn, TypeScaleTokens.bodyCkb),
      bodyStrong: s(
        TypeScaleTokens.bodyStrongEn,
        TypeScaleTokens.bodyStrongCkb,
      ),
      label: s(TypeScaleTokens.labelEn, TypeScaleTokens.labelCkb),
      caption: s(TypeScaleTokens.captionEn, TypeScaleTokens.captionCkb),
      button: s(TypeScaleTokens.buttonEn, TypeScaleTokens.buttonCkb),
      numericBody: s(
        TypeScaleTokens.numericBodyEn,
        TypeScaleTokens.numericBodyCkb,
      ),
      numericTotal: s(
        TypeScaleTokens.numericTotalEn,
        TypeScaleTokens.numericTotalCkb,
      ),
      numericMetric: s(
        TypeScaleTokens.numericMetricEn,
        TypeScaleTokens.numericMetricCkb,
      ),
    );
  }

  final ScriptKind script;
  final TextStyle titleLarge;
  final TextStyle title;
  final TextStyle heading;

  /// Section label. Uppercase only for Latin script; apply with
  /// [overlineText].
  final TextStyle overline;
  final TextStyle bodyLarge;
  final TextStyle body;
  final TextStyle bodyStrong;
  final TextStyle label;
  final TextStyle caption;
  final TextStyle button;
  final TextStyle numericBody;
  final TextStyle numericTotal;
  final TextStyle numericMetric;

  /// Arabic script has no case; never uppercase it.
  String overlineText(String text) =>
      script == ScriptKind.latin ? text.toUpperCase() : text;

  static TextStyle _style(TypeSpec spec) => TextStyle(
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFallback,
    fontSize: spec.size,
    height: spec.line / spec.size,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: _weight(spec.weight),
    letterSpacing: spec.trackingEm * spec.size,
    fontFeatures: spec.tabular ? const [FontFeature.tabularFigures()] : null,
  );

  static FontWeight _weight(int w) => switch (w) {
    >= 700 => FontWeight.w700,
    >= 600 => FontWeight.w600,
    >= 500 => FontWeight.w500,
    _ => FontWeight.w400,
  };

  @override
  AppTypography copyWith() => this;

  @override
  AppTypography lerp(covariant AppTypography? other, double t) =>
      t < 0.5 || other == null ? this : other;
}
