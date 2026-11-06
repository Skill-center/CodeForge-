/// The editor page's appearance, derived from the app's own tokens: the page
/// is styled from the same CfColors as everything around it, so the editor
/// follows theme switches and the user's text scale.
library;

import 'package:flutter/painting.dart';

import '../../../design_system/tokens/colors.dart';

/// Font sizes the protocol accepts (editor.configure `fontSize`).
const double minEditorFontSize = 8;
const double maxEditorFontSize = 40;

/// The `editor.configure` payload for [colors], [dark] mode and an already
/// text-scaled [fontSize] (logical pixels; CSS pixels match them).
Map<String, Object?> editorConfiguration(
  CfColors colors, {
  required bool dark,
  required double fontSize,
}) {
  return {
    'palette': {
      'dark': dark,
      'background': cssHex(colors.surfaceSunken),
      'foreground': cssHex(colors.textPrimary),
      'gutterBackground': cssHex(colors.surfaceSunken),
      'gutterForeground': cssHex(colors.textDisabled),
      'activeLine': cssHex(colors.surfacePanel),
      'selection': cssHex(colors.accentEmber.withValues(alpha: 0.28)),
      'cursor': cssHex(colors.accentEmber),
      'matchingBracket': cssHex(colors.borderStrong),
      'searchMatch': cssHex(colors.warning.withValues(alpha: 0.32)),
      'panelBackground': cssHex(colors.surfacePanel),
      'border': cssHex(colors.borderSubtle),
      'syntax': {
        'keyword': cssHex(colors.syntaxKeyword),
        'string': cssHex(colors.syntaxString),
        'number': cssHex(colors.syntaxNumber),
        'function': cssHex(colors.syntaxFunction),
        'type': cssHex(colors.syntaxType),
        'comment': cssHex(colors.syntaxComment),
        'operator': cssHex(colors.syntaxOperator),
      },
    },
    'fontSize': fontSize.clamp(minEditorFontSize, maxEditorFontSize).toDouble(),
  };
}

/// `#RRGGBB`, or `#RRGGBBAA` when translucent. CSS puts alpha last; Flutter's
/// ARGB puts it first.
String cssHex(Color color) {
  final argb = color.toARGB32();
  String byte(int shift) =>
      ((argb >> shift) & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
  final rgb = '#${byte(16)}${byte(8)}${byte(0)}';
  return byte(24) == 'FF' ? rgb : '$rgb${byte(24)}';
}
