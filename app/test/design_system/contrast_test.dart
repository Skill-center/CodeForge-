/// WCAG AA contrast gate (G4). Computes relative luminance per WCAG 2.x
/// and asserts ≥4.5:1 for every text-bearing token on every surface it
/// can appear on. This test is the authority — docs mirror its results.
library;

import 'dart:math' as math;

import 'package:codeforge/design_system/tokens/colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _channel(double c) {
  return c <= 0.04045
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(Color color) {
  return 0.2126 * _channel(color.r) +
      0.7152 * _channel(color.g) +
      0.0722 * _channel(color.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  const minimum = 4.5;

  void checkTheme(String name, CfColors colors) {
    final surfaces = <String, Color>{
      'base': colors.surfaceBase,
      'panel': colors.surfacePanel,
      'raised': colors.surfaceRaised,
      'sunken': colors.surfaceSunken,
    };
    final foregrounds = <String, Color>{
      'textPrimary': colors.textPrimary,
      'textSecondary': colors.textSecondary,
      'accentEmber': colors.accentEmber,
      'success': colors.success,
      'warning': colors.warning,
      'danger': colors.danger,
      'info': colors.info,
    };
    for (final fg in foregrounds.entries) {
      for (final bg in surfaces.entries) {
        test('$name: ${fg.key} on ${bg.key} ≥ 4.5:1', () {
          final ratio = _contrast(fg.value, bg.value);
          expect(
            ratio,
            greaterThanOrEqualTo(minimum),
            reason: '${fg.key} on ${bg.key} = ${ratio.toStringAsFixed(2)}:1',
          );
        });
      }
    }

    final syntax = <String, Color>{
      'keyword': colors.syntaxKeyword,
      'string': colors.syntaxString,
      'number': colors.syntaxNumber,
      'function': colors.syntaxFunction,
      'type': colors.syntaxType,
      'comment': colors.syntaxComment,
      'operator': colors.syntaxOperator,
    };
    for (final token in syntax.entries) {
      test('$name: syntax ${token.key} on sunken ≥ 4.5:1', () {
        final ratio = _contrast(token.value, colors.surfaceSunken);
        expect(ratio, greaterThanOrEqualTo(minimum));
      });
    }

    test('$name: onAccent on accentEmber ≥ 4.5:1', () {
      expect(
        _contrast(colors.onAccent, colors.accentEmber),
        greaterThanOrEqualTo(minimum),
      );
    });
  }

  group('dark theme', () => checkTheme('dark', CfColors.dark));
  group('light theme', () => checkTheme('light', CfColors.light));
}
