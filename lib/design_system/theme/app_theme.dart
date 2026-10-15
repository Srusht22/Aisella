import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../tokens/tokens.g.dart';
import 'typography.dart';

/// Builds the Aisellia theme for a brightness and locale (Phase 2 §2–§5).
///
/// Material is used as the widget toolkit, but visual decisions come from the
/// tokens: no ink ripples (Phase 2 press feedback is a subtle overlay),
/// platform-native page transitions (DD-11), Phosphor icons for system
/// back/close affordances.
ThemeData buildAppTheme({
  required Brightness brightness,
  required Locale locale,
}) {
  final p = brightness == Brightness.dark
      ? AiselliaPalette.dark
      : AiselliaPalette.light;
  final type = AppTypography.forScript(scriptFor(locale));

  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.brandPrimary,
    onPrimary: p.textOnBrand,
    secondary: p.textBrand,
    onSecondary: p.textOnBrand,
    error: p.dangerFg,
    onError: p.dangerOnFill,
    surface: p.bgSurface,
    onSurface: p.textPrimary,
    onSurfaceVariant: p.textSecondary,
    surfaceContainerLowest: p.bgCanvas,
    surfaceContainerLow: p.bgCanvas,
    surfaceContainer: p.bgSurface,
    surfaceContainerHigh: p.bgRaised,
    surfaceContainerHighest: p.bgSunken,
    outline: p.borderControl,
    outlineVariant: p.borderHairline,
    scrim: p.scrim,
    shadow: const Color(0xFF101216),
  );

  TextStyle c(TextStyle s, Color color) => s.copyWith(color: color);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bgCanvas,
    canvasColor: p.bgCanvas,
    fontFamily: kFontFamily,
    fontFamilyFallback: kFontFallback,
    extensions: [p, type],
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.textPrimary.withValues(
      alpha: brightness == Brightness.dark ? 0.10 : 0.06,
    ),
    hoverColor: p.textPrimary.withValues(alpha: 0.04),
    focusColor: p.borderFocus.withValues(alpha: 0.12),
    dividerColor: p.borderHairline,
    dividerTheme: DividerThemeData(
      color: p.borderHairline,
      thickness: Strokes.hairline,
      space: Strokes.hairline,
    ),
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    textTheme: TextTheme(
      headlineSmall: c(type.titleLarge, p.textPrimary),
      titleLarge: c(type.title, p.textPrimary),
      titleMedium: c(type.heading, p.textPrimary),
      bodyLarge: c(type.bodyLarge, p.textPrimary),
      bodyMedium: c(type.body, p.textPrimary),
      bodySmall: c(type.caption, p.textSecondary),
      labelLarge: c(type.button, p.textPrimary),
      labelMedium: c(type.label, p.textSecondary),
      labelSmall: c(type.caption, p.textSecondary),
    ),
    iconTheme: IconThemeData(color: p.textPrimary, size: Sizes.iconLg),
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (_) =>
          const Icon(AppIcons.caretLeft, size: Sizes.iconLg),
      closeButtonIconBuilder: (_) => const Icon(AppIcons.x, size: Sizes.iconLg),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bgCanvas,
      foregroundColor: p.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: LayoutTokens.appBarHeight,
      titleTextStyle: c(type.title, p.textPrimary),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: c(type.caption, p.bgSurface),
      decoration: BoxDecoration(
        color: p.textPrimary,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.bgRaised,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: p.scrim.withValues(alpha: p.scrimOpacity),
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.bgRaised,
      surfaceTintColor: Colors.transparent,
      barrierColor: p.scrim.withValues(alpha: p.scrimOpacity),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      titleTextStyle: c(type.title, p.textPrimary),
      contentTextStyle: c(type.body, p.textSecondary),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.textPrimary,
      contentTextStyle: c(type.body, p.bgSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.brandPrimary,
      selectionColor: p.brandPrimary.withValues(alpha: 0.24),
      selectionHandleColor: p.brandPrimary,
    ),
  );
}
