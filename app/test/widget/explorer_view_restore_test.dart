/// The explorer's view after a restart (Phase 3 W3, gate G5): the folders
/// that were expanded are expanded again, the tree scrolls back to where
/// it was once the folders it needs are listed, and changes reach the
/// session store a moment later.
library;

import 'package:codeforge/application/explorer_view_controller.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/memory_file_service.dart';
import 'test_harness.dart';

/// A project with a folder long enough to scroll through.
MemoryFileService _longProject() => MemoryFileService(
  seed: {
    for (var i = 0; i < 60; i++)
      'docs/note_${i.toString().padLeft(2, '0')}.md': 'note $i\n',
    'src/main.js': 'run();\n',
    'main.js': 'main();\n',
  },
);

ScrollController _treeScroll(WidgetTester tester) => tester
    .widget<ListView>(find.byKey(const ValueKey('explorer_tree')))
    .controller!;

/// Lets the restore's retries and the view's delayed save run.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('expanded folders and the scroll come back after a restart', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final sessions = MemorySessionStore();
    await sessions.saveView(
      demoWorkspaceId,
      const ExplorerView(expanded: {'docs'}, scrollOffset: 600),
    );
    final harness = TestHarness(
      files: _longProject(),
      sessionStore: sessions,
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await _settle(tester);

    expect(find.byKey(const ValueKey('tree_docs/note_00.md')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree_src/main.js')), findsNothing);
    expect(_treeScroll(tester).offset, 600);
  });

  testWidgets('changes to the view are stored a moment later', (tester) async {
    setSurface(tester, 1280, 800);
    final sessions = MemorySessionStore();
    final harness = TestHarness(
      files: _longProject(),
      sessionStore: sessions,
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tree_docs')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tree_docs/note_00.md')), findsOneWidget);
    _treeScroll(tester).jumpTo(300);
    await tester.pump(
      ExplorerViewController.saveDelay + const Duration(milliseconds: 100),
    );
    final view = sessions.views[demoWorkspaceId];
    expect(view?.expanded, {'docs'});
    expect(view?.scrollOffset, 300);
    await tester.pump(const Duration(milliseconds: 500));
  });
}
