/// "Forge" color tokens — single source of truth (docs/UI_DESIGN_SYSTEM.md §1).
///
/// No widget may hardcode a color; everything reads [CfColors] from the theme.
/// The contrast test (test/design_system/contrast_test.dart) enforces WCAG AA
/// on every text/surface pair listed there.
library;

import 'package:material_ui/material_ui.dart';

/// Semantic color set for one brightness.
@immutable
final class CfColors extends ThemeExtension<CfColors> {
  const CfColors({
    required this.surfaceBase,
    required this.surfacePanel,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.borderSubtle,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.accentEmber,
    required this.accentEmberSoft,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.syntaxKeyword,
    required this.syntaxString,
    required this.syntaxNumber,
    required this.syntaxFunction,
    required this.syntaxType,
    required this.syntaxComment,
    required this.syntaxOperator,
  });

  final Color surfaceBase;
  final Color surfacePanel;
  final Color surfaceRaised;
  final Color surfaceSunken;
  final Color borderSubtle;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color accentEmber;
  final Color accentEmberSoft;
  final Color onAccent;
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color syntaxKeyword;
  final Color syntaxString;
  final Color syntaxNumber;
  final Color syntaxFunction;
  final Color syntaxType;
  final Color syntaxComment;
  final Color syntaxOperator;

  /// Dark — the primary CodeForge appearance.
  static const CfColors dark = CfColors(
    surfaceBase: Color(0xFF0F1115),
    surfacePanel: Color(0xFF161920),
    surfaceRaised: Color(0xFF1D2129),
    surfaceSunken: Color(0xFF0B0D10),
    borderSubtle: Color(0xFF262B35),
    borderStrong: Color(0xFF39404D),
    textPrimary: Color(0xFFE8EAF0),
    textSecondary: Color(0xFF9AA1B0),
    textDisabled: Color(0xFF5C6270),
    accentEmber: Color(0xFFFF7A45),
    accentEmberSoft: Color(0x24FF7A45),
    onAccent: Color(0xFF1A0E06),
    success: Color(0xFF4ADE80),
    warning: Color(0xFFFBBF24),
    danger: Color(0xFFF87171),
    info: Color(0xFF60A5FA),
    syntaxKeyword: Color(0xFFC792EA),
    syntaxString: Color(0xFFA5D6A7),
    syntaxNumber: Color(0xFFF78C6C),
    syntaxFunction: Color(0xFF82AAFF),
    syntaxType: Color(0xFFFFCB6B),
    syntaxComment: Color(0xFF8A93A6),
    syntaxOperator: Color(0xFF89DDFF),
  );

  /// Light — warm paper, same semantic structure.
  static const CfColors light = CfColors(
    surfaceBase: Color(0xFFFAFAF8),
    surfacePanel: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF1F0EC),
    surfaceSunken: Color(0xFFEFEDE8),
    borderSubtle: Color(0xFFE2E0DA),
    borderStrong: Color(0xFFC9C6BE),
    textPrimary: Color(0xFF1B1E24),
    textSecondary: Color(0xFF5B6068),
    textDisabled: Color(0xFFA6A9AE),
    // Contrast-audited 2026-11-05: every value ≥4.5:1 on all four light
    // surfaces (test/design_system/contrast_test.dart is the CI authority).
    accentEmber: Color(0xFFB93E0C),
    accentEmberSoft: Color(0x1FB93E0C),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF166534),
    warning: Color(0xFF92400E),
    danger: Color(0xFFB91C1C),
    info: Color(0xFF1D4ED8),
    syntaxKeyword: Color(0xFF7C3AED),
    syntaxString: Color(0xFF166534),
    syntaxNumber: Color(0xFFB93E0C),
    syntaxFunction: Color(0xFF1D4ED8),
    syntaxType: Color(0xFF92400E),
    syntaxComment: Color(0xFF5B6068),
    syntaxOperator: Color(0xFF0E7490),
  );

  /// Accessor: `Theme.of(context).extension<CfColors>()!` is verbose.
  static CfColors of(BuildContext context) =>
      Theme.of(context).extension<CfColors>()!;

  @override
  CfColors copyWith({
    Color? surfaceBase,
    Color? surfacePanel,
    Color? surfaceRaised,
    Color? surfaceSunken,
    Color? borderSubtle,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? accentEmber,
    Color? accentEmberSoft,
    Color? onAccent,
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? syntaxKeyword,
    Color? syntaxString,
    Color? syntaxNumber,
    Color? syntaxFunction,
    Color? syntaxType,
    Color? syntaxComment,
    Color? syntaxOperator,
  }) {
    return CfColors(
      surfaceBase: surfaceBase ?? this.surfaceBase,
      surfacePanel: surfacePanel ?? this.surfacePanel,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      borderStrong: borderStrong ?? this.borderStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textDisabled: textDisabled ?? this.textDisabled,
      accentEmber: accentEmber ?? this.accentEmber,
      accentEmberSoft: accentEmberSoft ?? this.accentEmberSoft,
      onAccent: onAccent ?? this.onAccent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      info: info ?? this.info,
      syntaxKeyword: syntaxKeyword ?? this.syntaxKeyword,
      syntaxString: syntaxString ?? this.syntaxString,
      syntaxNumber: syntaxNumber ?? this.syntaxNumber,
      syntaxFunction: syntaxFunction ?? this.syntaxFunction,
      syntaxType: syntaxType ?? this.syntaxType,
      syntaxComment: syntaxComment ?? this.syntaxComment,
      syntaxOperator: syntaxOperator ?? this.syntaxOperator,
    );
  }

  @override
  CfColors lerp(ThemeExtension<CfColors>? other, double t) {
    if (other is! CfColors) {
      return this;
    }
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return CfColors(
      surfaceBase: mix(surfaceBase, other.surfaceBase),
      surfacePanel: mix(surfacePanel, other.surfacePanel),
      surfaceRaised: mix(surfaceRaised, other.surfaceRaised),
      surfaceSunken: mix(surfaceSunken, other.surfaceSunken),
      borderSubtle: mix(borderSubtle, other.borderSubtle),
      borderStrong: mix(borderStrong, other.borderStrong),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textDisabled: mix(textDisabled, other.textDisabled),
      accentEmber: mix(accentEmber, other.accentEmber),
      accentEmberSoft: mix(accentEmberSoft, other.accentEmberSoft),
      onAccent: mix(onAccent, other.onAccent),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      info: mix(info, other.info),
      syntaxKeyword: mix(syntaxKeyword, other.syntaxKeyword),
      syntaxString: mix(syntaxString, other.syntaxString),
      syntaxNumber: mix(syntaxNumber, other.syntaxNumber),
      syntaxFunction: mix(syntaxFunction, other.syntaxFunction),
      syntaxType: mix(syntaxType, other.syntaxType),
      syntaxComment: mix(syntaxComment, other.syntaxComment),
      syntaxOperator: mix(syntaxOperator, other.syntaxOperator),
    );
  }
}
