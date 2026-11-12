/// Goldens of Phase 3's chrome that no screen golden shows (PHASE_3_PLAN
/// W6, "goldens cover the new chrome"): Home's recents in every status, the
/// explorer's menu, the banner of a file that changed on disk under unsaved
/// text, and Settings → Privacy. Baselines are generated on the CI Linux
/// runner via the [bootstrap] flow, like the other goldens.
@Tags(['golden'])
library;

import 'package:codeforge/application/file_watch_controller.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_storage_broker.dart';
import '../support/memory_project_storage.dart';
import '../widget/test_harness.dart';

const String _documents = 'content://com.android.externalstorage.documents';

Future<void> _expectGolden(WidgetTester tester, String file) async {
  expect(tester.takeException(), isNull);
  await expectLater(find.byType(MaterialApp), matchesGoldenFile(file));
  // Let the shell's debounced persistence timer fire before teardown.
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('home recents 412x915 dark', (tester) async {
    setSurface(tester, 412, 915);
    const project = ProjectLocation(
      id: 'project-a',
      name: 'a-project-with-a-rather-long-name',
      folder: 'a-project-with-a-rather-long-name',
    );
    const gone = ProjectLocation(id: 'project-g', name: 'gone', folder: 'gone');
    const folder = FolderLocation(
      treeUri: '$_documents/tree/primary%3ADocuments%2Fnotes',
      name: 'notes',
    );
    const lost = FolderLocation(
      treeUri: '$_documents/tree/primary%3Alost',
      name: 'lost',
    );
    final sessions = MemorySessionStore();
    // Touched in turn: the lost folder is the newest.
    for (final workspace in <WorkspaceLocation>[project, gone, folder, lost]) {
      await sessions.touchWorkspace(
        workspace,
        displayPath: displayPathOf(workspace),
      );
    }
    final broker = FakeStorageBroker()
      ..addTree(folder.treeUri, folder.name)
      ..addTree(lost.treeUri, lost.name, grant: false);
    await tester.pumpWidget(
      TestHarness(
        sessionStore: sessions,
        broker: broker,
        projects: MemoryProjectStorage()..add(project.folder),
      ).app(),
    );
    await tester.pumpAndSettle();
    final recents = find.byKey(const ValueKey('recents'));
    await tester.scrollUntilVisible(
      recents,
      120,
      scrollable: find
          .ancestor(
            of: find.byKey(const ValueKey('new_project')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('recent_${lost.id}')), findsOneWidget);
    await _expectGolden(tester, 'chrome/home_recents_412x915_dark.png');
  });

  testWidgets('explorer menu 1280x800 dark', (tester) async {
    setSurface(tester, 1280, 800);
    await tester.pumpWidget(
      TestHarness(shell: const ShellState(lastRoute: '/workspace')).app(),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('tree_main.js')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('explorer_menu_rename')), findsOneWidget);
    await _expectGolden(tester, 'chrome/explorer_menu_1280x800_dark.png');
  });

  testWidgets('changed on disk under unsaved text 412x915 dark', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(
        lastRoute: '/workspace',
        terminalStop: TerminalStop.closed,
      ),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    harness.editorSurface.typeText('// mine\n');
    await tester.pumpAndSettle();
    harness.files.putText('main.js', '// theirs\n');
    await tester.pump(
      const FileWatchSettings().batch + const Duration(milliseconds: 50),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('disk_conflict_notice')), findsOneWidget);
    await _expectGolden(tester, 'chrome/disk_conflict_412x915_dark.png');
  });

  testWidgets('settings privacy 412x915 dark', (tester) async {
    setSurface(tester, 412, 915);
    await tester.pumpWidget(
      TestHarness(shell: const ShellState(lastRoute: '/settings')).app(),
    );
    await tester.pumpAndSettle();
    final backup = find.byKey(const ValueKey('settings_backup'));
    await tester.scrollUntilVisible(
      backup,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(backup);
    await tester.pumpAndSettle();
    await _expectGolden(tester, 'chrome/settings_privacy_412x915_dark.png');
  });
}
