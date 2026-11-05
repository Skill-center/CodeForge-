import 'package:codeforge/design_system/components/workbench_chrome.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_harness.dart';

void main() {
  testWidgets('dirty dot appears on simulate-edit and clears on save', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    // Save is disabled while clean.
    final saveBefore = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('demo_save')),
        matching: find.byType(InkWell),
      ),
    );
    expect(saveBefore.onTap, isNull);

    await tester.tap(find.byKey(const ValueKey('demo_edit')));
    await tester.pumpAndSettle();
    expect(find.text('●'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('demo_save')));
    await tester.pumpAndSettle();
    expect(find.text('●'), findsNothing);
  });

  testWidgets('closing the active tab falls back to the previous tab', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    // The docked explorer also lists these filenames, so scope tab-text
    // assertions to the tab strip itself.
    Finder tabText(String label) => find.descendant(
      of: find.byType(CfTabStrip),
      matching: find.text(label),
    );

    // Open a second file from the docked explorer.
    await tester.tap(find.byKey(const ValueKey('tree_app.py')));
    await tester.pumpAndSettle();
    expect(tabText('app.py'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tab_close_app.py')));
    await tester.pumpAndSettle();
    expect(tabText('app.py'), findsNothing);
    expect(tabText('main.js'), findsOneWidget);
  });

  testWidgets('symbol toolbar is visibly disabled with a phase note', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Read-only preview — editing arrives in Phase 2.'),
        findsOneWidget);
  });
}
