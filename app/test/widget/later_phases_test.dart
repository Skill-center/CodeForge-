/// What the app says is still to come (Phase 3 W7): Settings' *Coming in
/// later phases* and the workbench's placeholder panels name ROADMAP's
/// phases, and nothing Phase 3 built is listed as coming.
library;

import 'package:codeforge/design_system/components/feedback.dart';
import 'package:codeforge/features/workbench/panels/placeholder_panels.dart';
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
    expect(find.text('Phase 4 — install and health'), findsOneWidget);
    expect(find.text('Phase 8 — curated catalog'), findsOneWidget);
    expect(find.text('Storage & folders'), findsNothing);
    expect(find.textContaining('Phase 3'), findsNothing);
  });

  const panels = <(String, Widget, String)>[
    ('search', SearchPanel(), 'Arrives in Phase 4'),
    ('source control', GitPanel(), 'Arrives in Phase 7'),
    ('extensions', ExtensionsPanel(), 'Arrives in Phase 8'),
    ('run', RunPanel(), 'Running arrives in Phase 5, debugging in Phase 9'),
  ];
  for (final (name, panel, note) in panels) {
    testWidgets('the $name panel says: $note', (tester) async {
      await tester.pumpWidget(TestHarness().wrap(Scaffold(body: panel)));
      await tester.pumpAndSettle();
      expect(find.text(note), findsOneWidget);
    });
  }

  testWidgets("the status strip's branch chip says when Git arrives", (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    await tester.pumpWidget(TestHarness().app());
    await tester.pumpAndSettle();
    await openDemoWorkspace(tester);

    final chip = tester.widget<CfStatusChip>(
      find.byKey(const ValueKey('status_branch')),
    );
    expect(chip.tooltip, 'Git arrives in Phase 7');
  });

  testWidgets('the search panel points to Go to File', (tester) async {
    await tester.pumpWidget(
      TestHarness().wrap(const Scaffold(body: SearchPanel())),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Go to File… in the command palette'),
      findsOneWidget,
    );
  });
}
