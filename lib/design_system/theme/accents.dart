import 'package:flutter/widgets.dart';

import '../../core/settings/app_settings.dart';
import '../tokens/tokens.g.dart';

/// The seed colours of one theme. [light] is the brand colour on light
/// backgrounds (white text on it); [dark] is the brand colour on dark
/// backgrounds, with [onDark] for text on it. [deep] closes the preview
/// gradient.
@immutable
class AccentSeed {
  const AccentSeed({
    required this.light,
    required this.dark,
    required this.onDark,
    required this.deep,
  });

  final Color light;
  final Color dark;
  final Color onDark;
  final Color deep;
}

const accentSeeds = <AppAccent, AccentSeed>{
  AppAccent.ledger: AccentSeed(
    light: Color(0xFF1F3F8F),
    dark: Color(0xFF9DB4F2),
    onDark: Color(0xFF0F1B3D),
    deep: Color(0xFF0E1E47),
  ),
  AppAccent.gold: AccentSeed(
    light: Color(0xFF7A5A12),
    dark: Color(0xFFE3C26B),
    onDark: Color(0xFF2A1F05),
    deep: Color(0xFF2B2109),
  ),
  AppAccent.emerald: AccentSeed(
    light: Color(0xFF0B6B4B),
    dark: Color(0xFF5BD3A0),
    onDark: Color(0xFF052A1C),
    deep: Color(0xFF042A1D),
  ),
  AppAccent.sapphire: AccentSeed(
    light: Color(0xFF0A5BB0),
    dark: Color(0xFF7DB8FF),
    onDark: Color(0xFF061C36),
    deep: Color(0xFF05254A),
  ),
  AppAccent.ruby: AccentSeed(
    light: Color(0xFF9E1B32),
    dark: Color(0xFFFF8A9B),
    onDark: Color(0xFF3A0710),
    deep: Color(0xFF3E0812),
  ),
  AppAccent.amethyst: AccentSeed(
    light: Color(0xFF6A3BA8),
    dark: Color(0xFFC3A6FF),
    onDark: Color(0xFF22103F),
    deep: Color(0xFF231040),
  ),
  AppAccent.rose: AccentSeed(
    light: Color(0xFFA2316A),
    dark: Color(0xFFFF9CC8),
    onDark: Color(0xFF3A0A22),
    deep: Color(0xFF3D0B25),
  ),
  AppAccent.teal: AccentSeed(
    light: Color(0xFF0B6E70),
    dark: Color(0xFF5ED6CF),
    onDark: Color(0xFF052A2A),
    deep: Color(0xFF042C2D),
  ),
  AppAccent.copper: AccentSeed(
    light: Color(0xFF9A4313),
    dark: Color(0xFFFFA772),
    onDark: Color(0xFF3A1604),
    deep: Color(0xFF3B1806),
  ),
  AppAccent.onyx: AccentSeed(
    light: Color(0xFF23262B),
    dark: Color(0xFFE8E6E1),
    onDark: Color(0xFF16171A),
    deep: Color(0xFF050506),
  ),
};

/// The palette for a theme and brightness. The brand roles take the seed;
/// the neutrals take a faint tint of it so the whole screen feels of one
/// piece. Status colours (success, warning, danger) never change, so their
/// meaning stays the same in every theme. `ledger` is the base palette
/// exactly.
AiselliaPalette accentPalette(AppAccent accent, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = dark ? AiselliaPalette.dark : AiselliaPalette.light;
  if (accent == AppAccent.ledger) return base;
  final seed = accentSeeds[accent]!;
  final brand = dark ? seed.dark : seed.light;
  Color tint(Color c, double a) =>
      Color.alphaBlend(brand.withValues(alpha: a), c);
  final pressed = dark
      ? Color.alphaBlend(const Color(0x33FFFFFF), brand)
      : Color.alphaBlend(const Color(0x33000000), brand);
  final weak = dark ? tint(base.bgSurface, 0.16) : tint(base.bgSurface, 0.10);
  return AiselliaPalette(
    bgCanvas: tint(base.bgCanvas, dark ? 0.04 : 0.03),
    bgSurface: tint(base.bgSurface, dark ? 0.05 : 0.0),
    bgRaised: tint(base.bgRaised, dark ? 0.06 : 0.0),
    bgSunken: tint(base.bgSunken, dark ? 0.03 : 0.04),
    bgPencil: tint(base.bgPencil, 0.04),
    bgBrandWeak: weak,
    textPrimary: base.textPrimary,
    textSecondary: base.textSecondary,
    textTertiary: base.textTertiary,
    textDisabled: base.textDisabled,
    textOnBrand: dark ? seed.onDark : const Color(0xFFFFFFFF),
    textBrand: brand,
    textPencil: base.textPencil,
    borderHairline: tint(base.borderHairline, dark ? 0.08 : 0.06),
    borderControl: base.borderControl,
    borderPencil: base.borderPencil,
    borderFocus: brand,
    brandPrimary: brand,
    brandPrimaryPressed: pressed,
    successFg: base.successFg,
    successBg: base.successBg,
    warningFg: base.warningFg,
    warningBg: base.warningBg,
    dangerFg: base.dangerFg,
    dangerFgOnBg: base.dangerFgOnBg,
    dangerBg: base.dangerBg,
    dangerOnFill: base.dangerOnFill,
    infoFg: brand,
    infoBg: weak,
    neutralBadgeBg: base.neutralBadgeBg,
    neutralBadgeFg: base.neutralBadgeFg,
    scrim: base.scrim,
    scrimOpacity: base.scrimOpacity,
  );
}
