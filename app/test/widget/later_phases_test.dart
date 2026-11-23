/// What the app says is still to come (Phase 3 W7): Settings' *Coming in
/// later phases* and the workbench's placeholder panels name ROADMAP's
/// phases, and nothing built already (Phase 3's folders, Phase 4's
/// runtime, Phase 5's Run) is listed as coming.
library;

import 'package:codeforge/features/workbench/panels/placeholder_panels.dart';
import 'package:codeforge/features/workbench/panels/run_panel.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'test_harness.dart';

void main() {
  testWidgets('Settings lists only what later phases bring', (tester) async {
    setSurface(tester, 412, 915);
    await tester.pumpWidget(
      TestHarness(shell: const ShellState(lastRoute: '/settings')).app(),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Phase 8 — curated catalog'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('COMING IN LATER PHASES'), findsOneWidget);
    expect(find.text('Phase 8 — curated catalog'), findsOneWidget);
    expect(find.text('Storage & folders'), findsNothing);
    expect(find.textContaining('Phase 3'), findsNothing);
    // The runtime arrived in Phase 4 W3: its own section, no longer coming.
    expect(find.text('Phase 4 — install and health'), findsNothing);
    expect(find.text('RUNTIME'), findsOneWidget);
  });

  const panels = <(String, Widget, String)>[
    ('source control', GitPanel(), 'Arrives in Phase 7'),
    ('extensions', ExtensionsPanel(), 'Arrives in Phase 8'),
    // Run arrived in Phase 5 W4; debugging is still to come.
    ('run', RunPanel(), 'Debugging arrives in Phase 9'),
  ];
  for (final (name, panel, note) in panels) {
    testWidgets('the $name panel says: $note', (tester) async {
      await tester.pumpWidget(TestHarness().wrap(Scaffold(body: panel)));
      await tester.pumpAndSettle();
      expect(find.text(note), findsOneWidget);
    });
  }

  // The branch chip became real in Phase 7 W2 (test/widget/git_chip_test.dart).
}
