/// ThemeData builders for the Forge design system.
library;

import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/geometry.dart';
import '../tokens/typography.dart';

abstract final class CfTheme {
  static ThemeData dark() => _build(CfColors.dark, Brightness.dark);

  static ThemeData light() => _build(CfColors.light, Brightness.light);

  static ThemeData _build(CfColors colors, Brightness brightness) {
    final textTheme = CfTypography.textTheme(colors);
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: colors.accentEmber,
      onPrimary: colors.onAccent,
      secondary: colors.info,
      onSecondary: colors.onAccent,
      error: colors.danger,
      onError: colors.onAccent,
      surface: colors.surfaceBase,
      onSurface: colors.textPrimary,
      surfaceContainerHighest: colors.surfaceRaised,
      outline: colors.borderStrong,
      outlineVariant: colors.borderSubtle,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colors.surfaceBase,
      canvasColor: colors.surfaceBase,
      dividerColor: colors.borderSubtle,
      fontFamily: CfTypography.uiFamily,
      textTheme: textTheme,
      extensions: [colors],
      splashFactory: InkRipple.splashFactory,
      appBarTheme: AppBarThemeData(
        backgroundColor: colors.surfacePanel,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleMedium,
      ),
      dividerTheme: DividerThemeData(
        color: colors.borderSubtle,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfacePanel,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(CfRadius.lg),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CfRadius.lg),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surfaceRaised,
        contentTextStyle: textTheme.bodyMedium,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CfRadius.md),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.surfaceRaised,
          borderRadius: BorderRadius.circular(CfRadius.sm),
          border: Border.all(color: colors.borderSubtle),
        ),
        textStyle: textTheme.bodySmall?.copyWith(color: colors.textPrimary),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: colors.surfaceSunken,
        hintStyle: textTheme.bodyMedium?.copyWith(color: colors.textDisabled),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CfRadius.sm),
          borderSide: BorderSide(color: colors.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CfRadius.sm),
          borderSide: BorderSide(color: colors.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CfRadius.sm),
          borderSide: BorderSide(color: colors.borderStrong, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: CfSpacing.md,
          vertical: CfSpacing.md,
        ),
        // Not dense: Material then keeps a field at least 48 dp tall with its
        // text centred. Dense, a labelled field came to 47 dp (G8).
        isDense: false,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: colors.accentEmber,
        inactiveTrackColor: colors.borderSubtle,
        thumbColor: colors.accentEmber,
        overlayColor: colors.accentEmberSoft,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colors.onAccent;
          }
          return colors.textSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colors.accentEmber;
          }
          return colors.surfaceSunken;
        }),
        trackOutlineColor: WidgetStatePropertyAll(colors.borderSubtle),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colors.accentEmberSoft;
            }
            return colors.surfaceSunken;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colors.accentEmber;
            }
            return colors.textSecondary;
          }),
          side: WidgetStatePropertyAll(BorderSide(color: colors.borderSubtle)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CfRadius.sm),
            ),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors.textSecondary,
        textColor: colors.textPrimary,
        titleTextStyle: textTheme.bodyMedium,
        subtitleTextStyle: textTheme.bodySmall,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CfRadius.md),
          side: BorderSide(color: colors.borderSubtle),
        ),
        textStyle: textTheme.bodyMedium,
      ),
    );
  }
}
