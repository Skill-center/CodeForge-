/// About's Legal section (Phase 5 W1): the written source offer for this
/// version, and CodeForge's own license.
library;

import 'package:codeforge/core/legal/source_offer.dart';
import 'package:codeforge/core/version.dart';
import 'package:codeforge/features/settings/about_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'test_harness.dart';

Future<void> _open(WidgetTester tester, String key) async {
  await tester.pumpWidget(TestHarness().wrap(const AboutScreen()));
  await tester.pumpAndSettle();
  final tile = find.byKey(ValueKey(key));
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Source code shows the written offer for this version', (
    tester,
  ) async {
    await _open(tester, 'about_source_code');
    expect(find.text('Source code'), findsOneWidget);
    for (final paragraph in sourceOfferParagraphs(appVersion)) {
      expect(find.text(paragraph), findsOneWidget);
    }
    expect(
      find.textContaining(sourceArchiveName(appVersion)),
      findsOneWidget,
    );
  });

  testWidgets("CodeForge's license shows the Apache License", (tester) async {
    // Loaded for real first: the screen then reads the bundle's cached copy.
    await tester.runAsync(() => rootBundle.loadString(codeForgeLicenseAsset));
    await _open(tester, 'about_codeforge_license');
    expect(find.text("CodeForge's license"), findsOneWidget);
    expect(find.textContaining('Version 2.0, January 2004'), findsOneWidget);
  });
}
