import 'package:codeforge/design_system/components/workbench_chrome.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_harness.dart';

void main() {
  testWidgets('typing in the editor marks the tab dirty; save clears it', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    // The workbench opened main.js, and the page shows it.
    final page = harness.editorSurface;
    expect(page.activeDocId, isNotNull);
    expect(
      page.documents[page.activeDocId]!.text,
      contains('CodeForge'),
      reason: 'main.js reached the page through doc.open',
    );
    expect(find.byKey(const ValueKey('fake_editor_text')), findsOneWidget);

    InkWell saveButton() => tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('editor_save')),
        matching: find.byType(InkWell),
      ),
    );
    // Save is disabled while clean.
    expect(saveButton().onTap, isNull);

    page.typeText('// typed\n');
    await tester.pumpAndSettle();
    expect(find.text('●'), findsOneWidget);
    expect(saveButton().onTap, isNotNull);

    await tester.tap(find.byKey(const ValueKey('editor_save')));
    await tester.pumpAndSettle();
    expect(find.text('●'), findsNothing);
    expect(saveButton().onTap, isNull);
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
    final page = harness.editorSurface;
    expect(page.documents, hasLength(2));
    final appId = page.activeDocId;

    await tester.tap(find.byKey(const ValueKey('tab_close_app.py')));
    await tester.pumpAndSettle();
    expect(tabText('app.py'), findsNothing);
    expect(tabText('main.js'), findsOneWidget);
    // The editor closed the document and shows the fallback.
    expect(page.documents.keys, isNot(contains(appId)));
    expect(page.documents, hasLength(1));
    expect(page.activeDocId, page.documents.keys.single);
  });

  testWidgets('the symbol toolbar stays visibly disabled with a phase note', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.text('Esc'), findsOneWidget);
    expect(find.byTooltip('Symbol keys arrive later in Phase 2'), findsOneWidget);
    // The Phase 1 read-only preview is gone: the pane hosts the editor.
    expect(find.textContaining('Read-only preview'), findsNothing);
    expect(find.byKey(const ValueKey('editor_surface')), findsOneWidget);
  });
}
