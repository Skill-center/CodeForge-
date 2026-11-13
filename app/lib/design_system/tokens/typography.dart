/// Typography — Inter for UI, JetBrains Mono for code
/// (docs/UI_DESIGN_SYSTEM.md §2). Both fonts are bundled; nothing is fetched.
library;

import 'package:material_ui/material_ui.dart';

import 'colors.dart';

abstract final class CfTypography {
  static const String uiFamily = 'Inter';
  static const String codeFamily = 'JetBrainsMono';

  static TextTheme textTheme(CfColors colors) {
    final base = TextTheme(
      displaySmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: colors.textPrimary,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: colors.textPrimary,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: colors.textPrimary,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: colors.textPrimary,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: colors.textPrimary,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.4,
        color: colors.textSecondary,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.35,
        color: colors.textPrimary,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.35,
        color: colors.textPrimary,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        height: 1.35,
        color: colors.textSecondary,
      ),
    );
    return base.apply(fontFamily: uiFamily);
  }

  /// Code specimen / future editor style. Programming ligatures are off by
  /// default on mobile for cursor clarity (UI_DESIGN_SYSTEM.md §2); JetBrains
  /// Mono implements them as contextual alternates, so `calt` is disabled
  /// along with standard `liga`.
  static TextStyle code(CfColors colors, {double fontSize = 14}) {
    return TextStyle(
      fontFamily: codeFamily,
      fontSize: fontSize,
      height: 1.5,
      color: colors.textPrimary,
      fontFeatures: const [
        FontFeature.disable('calt'),
        FontFeature.disable('liga'),
      ],
    );
  }

  /// Tabular numerals for status strip / counters.
  static TextStyle status(CfColors colors) {
    return TextStyle(
      fontFamily: uiFamily,
      fontSize: 11,
      fontWeight: FontWeight.w500,
      height: 1.2,
      color: colors.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }
}
