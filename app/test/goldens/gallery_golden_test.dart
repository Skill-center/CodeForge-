/// Golden tests for the Forge gallery (G3). Baselines are generated on the
/// CI Linux runner via the [bootstrap] flow and committed; local runs on
/// other platforms should use --update-goldens on CI only.
@Tags(['golden'])
library;

import 'package:codeforge/design_system/theme/theme.dart';
import 'package:codeforge/features/settings/dev_gallery_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../widget/test_harness.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('gallery ${brightness.name}', (tester) async {
      setSurface(tester, 412, 2800);
      final theme = brightness == Brightness.dark
          ? CfTheme.dark()
          : CfTheme.light();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: const Scaffold(
            body: SingleChildScrollView(child: GalleryBody()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(GalleryBody),
        matchesGoldenFile('gallery_${brightness.name}.png'),
      );
    });
  }
}
