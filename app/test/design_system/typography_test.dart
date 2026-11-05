/// Typography tokens match docs/UI_DESIGN_SYSTEM.md §2, so the document and
/// the code cannot drift apart silently.
library;

import 'package:codeforge/design_system/tokens/colors.dart';
import 'package:codeforge/design_system/tokens/typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final entry in {
    'dark': CfColors.dark,
    'light': CfColors.light,
  }.entries) {
    group('${entry.key} theme', () {
      final theme = CfTypography.textTheme(entry.value);

      void expectRole(
        String role,
        TextStyle? style,
        double size,
        FontWeight weight,
      ) {
        expect(style, isNotNull, reason: role);
        expect(style!.fontFamily, CfTypography.uiFamily, reason: role);
        expect(style.fontSize, size, reason: role);
        expect(style.fontWeight, weight, reason: role);
        expect(style.height, inInclusiveRange(1.35, 1.45), reason: role);
      }

      test('UI scale: display 24/600 · title 18/600 · body 14/400 · '
          'label 12/500 · caption 11/400 (Inter, height 1.35–1.45)', () {
        expectRole('display', theme.displaySmall, 24, FontWeight.w600);
        expectRole('title', theme.titleLarge, 18, FontWeight.w600);
        expectRole('body', theme.bodyMedium, 14, FontWeight.w400);
        expectRole('label', theme.labelMedium, 12, FontWeight.w500);
        expectRole('caption', theme.labelSmall, 11, FontWeight.w400);
      });

      test('code: JetBrains Mono, 14 by default, ligatures off', () {
        final code = CfTypography.code(entry.value);
        expect(code.fontFamily, CfTypography.codeFamily);
        expect(code.fontSize, 14);
        expect(
          code.fontFeatures,
          containsAll(const [
            FontFeature.disable('calt'),
            FontFeature.disable('liga'),
          ]),
        );
      });

      test('status text uses tabular figures', () {
        expect(
          CfTypography.status(entry.value).fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
      });
    });
  }
}
