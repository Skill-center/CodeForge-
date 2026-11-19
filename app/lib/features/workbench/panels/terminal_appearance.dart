/// The terminal page's appearance (Phase 5 W3), derived from the app's own
/// tokens like the editor's (editor_appearance.dart): the terminal follows
/// theme switches and the user's text scale.
///
/// The tokens have no ANSI palette, so one is built from them: red, green,
/// yellow and blue are the status colours, magenta and cyan the keyword and
/// operator colours, and black and white the surfaces' extremes. The bright
/// eight are the same mixed towards white (dark) or black (light).
library;

import 'package:flutter/painting.dart';

import '../../../design_system/tokens/colors.dart';
import 'editor_appearance.dart' show cssHex;

/// Font sizes the protocol accepts (terminal.configure `fontSize`).
const double minTerminalFontSize = 8;
const double maxTerminalFontSize = 40;

/// The `terminal.configure` payload for [colors], [dark] mode and an
/// already text-scaled [fontSize] (logical pixels, which CSS pixels match).
Map<String, Object?> terminalConfiguration(
  CfColors colors, {
  required bool dark,
  required double fontSize,
}) {
  final black = dark ? colors.surfaceRaised : colors.textPrimary;
  final white = dark ? colors.textPrimary : colors.surfaceRaised;
  final towards = dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  Color bright(Color color) => Color.lerp(color, towards, dark ? 0.3 : 0.2)!;
  final brightWhite = dark ? const Color(0xFFFFFFFF) : colors.surfacePanel;
  final base = <String, Color>{
    'black': black,
    'red': colors.danger,
    'green': colors.success,
    'yellow': colors.warning,
    'blue': colors.info,
    'magenta': colors.syntaxKeyword,
    'cyan': colors.syntaxOperator,
    'white': white,
  };
  return {
    'theme': {
      'dark': dark,
      'background': cssHex(colors.surfaceSunken),
      'foreground': cssHex(colors.textPrimary),
      'cursor': cssHex(colors.accentEmber),
      'cursorAccent': cssHex(colors.surfaceSunken),
      'selection': cssHex(colors.accentEmber.withValues(alpha: 0.28)),
      for (final MapEntry(:key, :value) in base.entries) key: cssHex(value),
      'brightBlack': cssHex(dark ? colors.textDisabled : colors.textSecondary),
      for (final MapEntry(:key, :value) in base.entries)
        if (key != 'black')
          'bright${key[0].toUpperCase()}${key.substring(1)}': cssHex(
            key == 'white' ? brightWhite : bright(value),
          ),
    },
    'fontSize': fontSize
        .clamp(minTerminalFontSize, maxTerminalFontSize)
        .toDouble(),
  };
}
