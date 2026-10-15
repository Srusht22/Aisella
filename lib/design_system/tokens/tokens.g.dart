// GENERATED CODE — DO NOT EDIT.
// Source: docs/design/phase-2/tokens/aisellia-tokens.json (version 0.1.0-proposal).
// Regenerate with: dart run tool/gen_tokens.dart

import 'package:flutter/material.dart' show ThemeExtension;
import 'package:flutter/widgets.dart';

/// Semantic colour palette (Phase 2 §2). Access via
/// `context.palette` (see design_system/theme/theme_ext.dart).
@immutable
final class AiselliaPalette extends ThemeExtension<AiselliaPalette> {
  const AiselliaPalette({
    required this.bgCanvas,
    required this.bgSurface,
    required this.bgRaised,
    required this.bgSunken,
    required this.bgPencil,
    required this.bgBrandWeak,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.textOnBrand,
    required this.textBrand,
    required this.textPencil,
    required this.borderHairline,
    required this.borderControl,
    required this.borderPencil,
    required this.borderFocus,
    required this.brandPrimary,
    required this.brandPrimaryPressed,
    required this.successFg,
    required this.successBg,
    required this.warningFg,
    required this.warningBg,
    required this.dangerFg,
    required this.dangerFgOnBg,
    required this.dangerBg,
    required this.dangerOnFill,
    required this.infoFg,
    required this.infoBg,
    required this.neutralBadgeBg,
    required this.neutralBadgeFg,
    required this.scrim,
    required this.scrimOpacity,
  });

  /// `bg.canvas`
  final Color bgCanvas;

  /// `bg.surface`
  final Color bgSurface;

  /// `bg.raised`
  final Color bgRaised;

  /// `bg.sunken`
  final Color bgSunken;

  /// `bg.pencil`
  final Color bgPencil;

  /// `bg.brandWeak`
  final Color bgBrandWeak;

  /// `text.primary`
  final Color textPrimary;

  /// `text.secondary`
  final Color textSecondary;

  /// `text.tertiary`
  final Color textTertiary;

  /// `text.disabled`
  final Color textDisabled;

  /// `text.onBrand`
  final Color textOnBrand;

  /// `text.brand`
  final Color textBrand;

  /// `text.pencil`
  final Color textPencil;

  /// `border.hairline`
  final Color borderHairline;

  /// `border.control`
  final Color borderControl;

  /// `border.pencil`
  final Color borderPencil;

  /// `border.focus`
  final Color borderFocus;

  /// `brand.primary`
  final Color brandPrimary;

  /// `brand.primaryPressed`
  final Color brandPrimaryPressed;

  /// `success.fg`
  final Color successFg;

  /// `success.bg`
  final Color successBg;

  /// `warning.fg`
  final Color warningFg;

  /// `warning.bg`
  final Color warningBg;

  /// `danger.fg`
  final Color dangerFg;

  /// `danger.fgOnBg`
  final Color dangerFgOnBg;

  /// `danger.bg`
  final Color dangerBg;

  /// `danger.onFill`
  final Color dangerOnFill;

  /// `info.fg`
  final Color infoFg;

  /// `info.bg`
  final Color infoBg;

  /// `neutral.badgeBg`
  final Color neutralBadgeBg;

  /// `neutral.badgeFg`
  final Color neutralBadgeFg;

  /// `scrim`
  final Color scrim;

  /// `scrim.opacity`
  final double scrimOpacity;

  static const AiselliaPalette light = AiselliaPalette(
    bgCanvas: Color(0xFFF6F4EF),
    bgSurface: Color(0xFFFFFFFF),
    bgRaised: Color(0xFFFFFFFF),
    bgSunken: Color(0xFFEFECE5),
    bgPencil: Color(0xFFF1EEE6),
    bgBrandWeak: Color(0xFFE8EDF8),
    textPrimary: Color(0xFF1A1C20),
    textSecondary: Color(0xFF555A63),
    textTertiary: Color(0xFF6B7079),
    textDisabled: Color(0xFF9EA2A9),
    textOnBrand: Color(0xFFFFFFFF),
    textBrand: Color(0xFF1F3F8F),
    textPencil: Color(0xFF4A4F59),
    borderHairline: Color(0xFFE4E0D7),
    borderControl: Color(0xFF80848C),
    borderPencil: Color(0xFF7A7F88),
    borderFocus: Color(0xFF1F3F8F),
    brandPrimary: Color(0xFF1F3F8F),
    brandPrimaryPressed: Color(0xFF18326F),
    successFg: Color(0xFF17663F),
    successBg: Color(0xFFE6F2EA),
    warningFg: Color(0xFF8A4B00),
    warningBg: Color(0xFFFCEFD6),
    dangerFg: Color(0xFFB42318),
    dangerFgOnBg: Color(0xFFA21D14),
    dangerBg: Color(0xFFFBE9E7),
    dangerOnFill: Color(0xFFFFFFFF),
    infoFg: Color(0xFF1F3F8F),
    infoBg: Color(0xFFE8EDF8),
    neutralBadgeBg: Color(0xFFECE9E2),
    neutralBadgeFg: Color(0xFF3F434A),
    scrim: Color(0xFF101216),
    scrimOpacity: 0.48,
  );

  static const AiselliaPalette dark = AiselliaPalette(
    bgCanvas: Color(0xFF121417),
    bgSurface: Color(0xFF1B1E23),
    bgRaised: Color(0xFF22262C),
    bgSunken: Color(0xFF0E1013),
    bgPencil: Color(0xFF1F2228),
    bgBrandWeak: Color(0xFF1D2740),
    textPrimary: Color(0xFFECEDEF),
    textSecondary: Color(0xFFA9AEB8),
    textTertiary: Color(0xFF8C929D),
    textDisabled: Color(0xFF5D626B),
    textOnBrand: Color(0xFF0F1B3D),
    textBrand: Color(0xFF9DB4F2),
    textPencil: Color(0xFFB9BDC6),
    borderHairline: Color(0xFF2A2E35),
    borderControl: Color(0xFF707682),
    borderPencil: Color(0xFF7A808B),
    borderFocus: Color(0xFF9DB4F2),
    brandPrimary: Color(0xFF9DB4F2),
    brandPrimaryPressed: Color(0xFFB7C8F5),
    successFg: Color(0xFF6CCB97),
    successBg: Color(0xFF15291F),
    warningFg: Color(0xFFF0B35B),
    warningBg: Color(0xFF2E2414),
    dangerFg: Color(0xFFF28B80),
    dangerFgOnBg: Color(0xFFF4A097),
    dangerBg: Color(0xFF33191A),
    dangerOnFill: Color(0xFF3A0D09),
    infoFg: Color(0xFF9DB4F2),
    infoBg: Color(0xFF1D2740),
    neutralBadgeBg: Color(0xFF2A2E35),
    neutralBadgeFg: Color(0xFFD3D6DC),
    scrim: Color(0xFF000000),
    scrimOpacity: 0.6,
  );

  @override
  AiselliaPalette copyWith() => this;

  @override
  AiselliaPalette lerp(covariant AiselliaPalette? other, double t) {
    if (other == null) return this;
    return AiselliaPalette(
      bgCanvas: Color.lerp(bgCanvas, other.bgCanvas, t)!,
      bgSurface: Color.lerp(bgSurface, other.bgSurface, t)!,
      bgRaised: Color.lerp(bgRaised, other.bgRaised, t)!,
      bgSunken: Color.lerp(bgSunken, other.bgSunken, t)!,
      bgPencil: Color.lerp(bgPencil, other.bgPencil, t)!,
      bgBrandWeak: Color.lerp(bgBrandWeak, other.bgBrandWeak, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      textOnBrand: Color.lerp(textOnBrand, other.textOnBrand, t)!,
      textBrand: Color.lerp(textBrand, other.textBrand, t)!,
      textPencil: Color.lerp(textPencil, other.textPencil, t)!,
      borderHairline: Color.lerp(borderHairline, other.borderHairline, t)!,
      borderControl: Color.lerp(borderControl, other.borderControl, t)!,
      borderPencil: Color.lerp(borderPencil, other.borderPencil, t)!,
      borderFocus: Color.lerp(borderFocus, other.borderFocus, t)!,
      brandPrimary: Color.lerp(brandPrimary, other.brandPrimary, t)!,
      brandPrimaryPressed: Color.lerp(
        brandPrimaryPressed,
        other.brandPrimaryPressed,
        t,
      )!,
      successFg: Color.lerp(successFg, other.successFg, t)!,
      successBg: Color.lerp(successBg, other.successBg, t)!,
      warningFg: Color.lerp(warningFg, other.warningFg, t)!,
      warningBg: Color.lerp(warningBg, other.warningBg, t)!,
      dangerFg: Color.lerp(dangerFg, other.dangerFg, t)!,
      dangerFgOnBg: Color.lerp(dangerFgOnBg, other.dangerFgOnBg, t)!,
      dangerBg: Color.lerp(dangerBg, other.dangerBg, t)!,
      dangerOnFill: Color.lerp(dangerOnFill, other.dangerOnFill, t)!,
      infoFg: Color.lerp(infoFg, other.infoFg, t)!,
      infoBg: Color.lerp(infoBg, other.infoBg, t)!,
      neutralBadgeBg: Color.lerp(neutralBadgeBg, other.neutralBadgeBg, t)!,
      neutralBadgeFg: Color.lerp(neutralBadgeFg, other.neutralBadgeFg, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      scrimOpacity: scrimOpacity + (other.scrimOpacity - scrimOpacity) * t,
    );
  }
}

/// 4-point spacing scale (Phase 2 §4.1). Names equal values.
abstract final class Space {
  static const double s0 = 0.0;
  static const double s2 = 2.0;
  static const double s4 = 4.0;
  static const double s8 = 8.0;
  static const double s12 = 12.0;
  static const double s16 = 16.0;
  static const double s20 = 20.0;
  static const double s24 = 24.0;
  static const double s32 = 32.0;
  static const double s40 = 40.0;
  static const double s48 = 48.0;
  static const double s64 = 64.0;
}

/// Corner radii (Phase 2 §5). Only these four exist.
abstract final class Radii {
  static const double sm = 6.0;
  static const double md = 10.0;
  static const double lg = 16.0;
  static const double full = 999.0;
}

/// Stroke widths and the pencil dash pattern (Phase 2 §1.1, §5).
abstract final class Strokes {
  static const double hairline = 1.0;
  static const double control = 1.0;
  static const double focus = 2.0;
  static const double pencil = 1.5;
  static const double pencilDash = 4.0;
  static const double pencilGap = 3.0;
}

/// Layout constants (Phase 2 §4.2).
abstract final class LayoutTokens {
  static const double breakpointCompact = 0.0;
  static const double breakpointMedium = 600.0;
  static const double breakpointExpanded = 840.0;
  static const double breakpointLarge = 1200.0;
  static const double compactSmallMaxWidth = 359.0;
  static const double compactSmallMaxHeight = 639.0;
  static const double gutterCompactSmall = 12.0;
  static const double gutterCompact = 16.0;
  static const double gutterMedium = 24.0;
  static const double gutterExpanded = 24.0;
  static const double gutterLarge = 32.0;
  static const double maxWidthForm = 560.0;
  static const double maxWidthReading = 680.0;
  static const double maxWidthListPane = 380.0;
  static const double maxWidthDetailPane = 840.0;
  static const double minTouchTarget = 48.0;
  static const double rowMinHeight = 48.0;
  static const double appBarHeight = 56.0;
  static const double bottomNavHeight = 64.0;
  static const double stickyActionBarMinHeight = 72.0;
}

/// Icon and media sizes (Phase 2 §6, §7).
abstract final class Sizes {
  static const double iconSm = 16.0;
  static const double iconMd = 20.0;
  static const double iconLg = 24.0;
  static const double thumbRow = 44.0;
  static const double thumbList = 56.0;
  static const double thumbPicker = 40.0;
  static const double thumbRadius = 6.0;
  static const double avatar = 36.0;
  static const double storeLogo = 40.0;
}

/// One entry of the per-script type scale (Phase 2 §3.2).
@immutable
final class TypeSpec {
  const TypeSpec({
    required this.size,
    required this.line,
    required this.weight,
    this.trackingEm = 0,
    this.uppercase = false,
    this.tabular = false,
  });
  final double size;
  final double line;
  final int weight;
  final double trackingEm;
  final bool uppercase;
  final bool tabular;
}

/// Type scale per script: `en` (Latin) and `ckb` (Arabic script).
abstract final class TypeScaleTokens {
  static const TypeSpec titleLargeEn = TypeSpec(
    size: 24.0,
    line: 32.0,
    weight: 600,
  );
  static const TypeSpec titleEn = TypeSpec(size: 18.0, line: 26.0, weight: 600);
  static const TypeSpec headingEn = TypeSpec(
    size: 16.0,
    line: 24.0,
    weight: 600,
  );
  static const TypeSpec overlineEn = TypeSpec(
    size: 12.0,
    line: 16.0,
    weight: 600,
    trackingEm: 0.06,
    uppercase: true,
  );
  static const TypeSpec bodyLargeEn = TypeSpec(
    size: 16.0,
    line: 24.0,
    weight: 400,
  );
  static const TypeSpec bodyEn = TypeSpec(size: 15.0, line: 22.0, weight: 400);
  static const TypeSpec bodyStrongEn = TypeSpec(
    size: 15.0,
    line: 22.0,
    weight: 600,
  );
  static const TypeSpec labelEn = TypeSpec(size: 13.0, line: 18.0, weight: 500);
  static const TypeSpec captionEn = TypeSpec(
    size: 12.0,
    line: 16.0,
    weight: 400,
  );
  static const TypeSpec buttonEn = TypeSpec(
    size: 15.0,
    line: 20.0,
    weight: 600,
  );
  static const TypeSpec numericBodyEn = TypeSpec(
    size: 15.0,
    line: 22.0,
    weight: 500,
    tabular: true,
  );
  static const TypeSpec numericTotalEn = TypeSpec(
    size: 20.0,
    line: 28.0,
    weight: 600,
    tabular: true,
  );
  static const TypeSpec numericMetricEn = TypeSpec(
    size: 28.0,
    line: 34.0,
    weight: 600,
    tabular: true,
  );
  static const TypeSpec titleLargeCkb = TypeSpec(
    size: 24.0,
    line: 38.0,
    weight: 600,
  );
  static const TypeSpec titleCkb = TypeSpec(
    size: 19.0,
    line: 30.0,
    weight: 600,
  );
  static const TypeSpec headingCkb = TypeSpec(
    size: 17.0,
    line: 28.0,
    weight: 600,
  );
  static const TypeSpec overlineCkb = TypeSpec(
    size: 13.0,
    line: 20.0,
    weight: 600,
  );
  static const TypeSpec bodyLargeCkb = TypeSpec(
    size: 17.0,
    line: 28.0,
    weight: 400,
  );
  static const TypeSpec bodyCkb = TypeSpec(size: 16.0, line: 26.0, weight: 400);
  static const TypeSpec bodyStrongCkb = TypeSpec(
    size: 16.0,
    line: 26.0,
    weight: 600,
  );
  static const TypeSpec labelCkb = TypeSpec(
    size: 14.0,
    line: 22.0,
    weight: 500,
  );
  static const TypeSpec captionCkb = TypeSpec(
    size: 13.0,
    line: 20.0,
    weight: 400,
  );
  static const TypeSpec buttonCkb = TypeSpec(
    size: 16.0,
    line: 24.0,
    weight: 600,
  );
  static const TypeSpec numericBodyCkb = TypeSpec(
    size: 15.0,
    line: 26.0,
    weight: 500,
    tabular: true,
  );
  static const TypeSpec numericTotalCkb = TypeSpec(
    size: 20.0,
    line: 30.0,
    weight: 600,
    tabular: true,
  );
  static const TypeSpec numericMetricCkb = TypeSpec(
    size: 28.0,
    line: 36.0,
    weight: 600,
    tabular: true,
  );
}

/// Motion tokens (Phase 2 §06). Use through `Motion`, which
/// applies the reduced-motion preference.
abstract final class MotionTokens {
  static const Duration instant = Duration(milliseconds: 0);
  static const Duration xs = Duration(milliseconds: 100);
  static const Duration sm = Duration(milliseconds: 160);
  static const Duration md = Duration(milliseconds: 200);
  static const Duration lg = Duration(milliseconds: 260);
  static const Duration xl = Duration(milliseconds: 300);
  static const Duration sheetEnter = Duration(milliseconds: 280);
  static const Duration sheetExit = Duration(milliseconds: 200);
  static const Duration numberRoll = Duration(milliseconds: 240);
  static const Duration inkSettle = Duration(milliseconds: 480);
  static const Cubic standard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Cubic enter = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Cubic exit = Cubic(0.3, 0.0, 0.8, 0.15);
  static const Curve linear = Curves.linear;
  static const double springMass = 1.0;
  static const double springStiffness = 400.0;
  static const double springDamping = 40.0;
  static const Duration staggerPerItem = Duration(milliseconds: 40);
  static const int staggerMaxItems = 4;
  static const double distanceSmall = 8.0;
  static const double distanceMedium = 30.0;
  static const Duration skeletonDelay = Duration(milliseconds: 300);
  static const Duration skeletonPulse = Duration(milliseconds: 1600);
  static const double skeletonMinOpacity = 0.6;
  static const double longContentCrossfadeThreshold = 600.0;
}
