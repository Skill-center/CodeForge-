/// Restore gate, part B (G5, and G3's tabs): after CI force-stopped the
/// process, launch fresh and assert the persisted state is restored on the
/// first frame — workbench route, light theme, terminal half-open — and
/// that the workspace open at the kill comes back. No prefs.clear() here.
///
/// Since Phase 3 W3 that workspace is the gate folder (G5): its tab
/// reopens with the unsaved text part A typed, and its expanded folders
/// show in the explorer. Home lists both workspaces, available. Switching
/// to the demo project brings back its two tabs, app.py active with its
/// unsaved text, its expanded folders and its explorer's scroll; switching
/// back finds the folder's unsaved text again, while the host finds the
/// file on disk unchanged (integration_test/folder_gate.dart).
///
/// And the log file (Phase 3 W1, G6): part A's last record, an error logged
/// just before the kill, is on disk before this session's marker.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/explorer_view_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/logging/file_log_sink.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_fixture.dart';
import 'folder_gate.dart';
import 'restore_a_test.dart'
    show
        restoreDemoExpanded,
        restoreDemoScroll,
        restoreDemoText,
        restoreFolderExpanded,
        restoreFolderText,
        restoreLogMarker,
        waitForPage;
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

/// Opens the explorer: the docked panel on wide screens is already there,
/// the phone's sheet opens from the activity bar.
Future<void> _showExplorer(WidgetTester tester) async {
  if (find.byKey(const ValueKey('explorer_tree')).evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('activity_explorer')));
  }
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('explorer_tree')).evaluate().isNotEmpty,
    what: 'the explorer',
  );
}

/// Closes the phone's explorer sheet (tap above it); nothing on wide
/// screens.
Future<void> _hideExplorer(WidgetTester tester) async {
  if (find.byType(DraggableScrollableSheet).evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
  }
}

/// From the workbench to Home, then into the recents' entry [id].
Future<void> _openRecent(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const ValueKey('workbench_home')));
  await tester.pumpAndSettle();
  final entry = find.byKey(ValueKey('recent_$id'));
  await pumpUntil(
    tester,
    () => entry.evaluate().isNotEmpty,
    what: 'the recents to list $id',
  );
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('restore B: state survives process death', (tester) async {
    final gate = await FolderGate.start();
    final prefs = await SharedPreferences.getInstance();
    // Precondition: part A ran and persisted.
    expect(
      prefs.getString(settingsStorageKey),
      contains('"themeMode":"light"'),
    );

    await pumpRealApp(tester, prefs);

    // Restored directly into the workbench — no home, no welcome.
    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('explore_demo')), findsNothing);
    expect(find.byKey(const ValueKey('welcome_dismiss')), findsNothing);

    // Theme restored.
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light);

    // Terminal stop restored.
    expect(find.text('TERMINAL'), findsOneWidget);

    // Envelope decodes to the exact state: the folder is the workspace.
    final shell = decodeShellState(prefs.getString(shellStateStorageKey));
    expect(shell.lastRoute, '/workspace');
    expect(shell.terminalStop, TerminalStop.half);
    final folder = shell.workspace;
    expect(folder, isA<FolderLocation>());
    expect(folder!.name, gateFolderName);

    // The folder's tab reopens from its file, with the unsaved text.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final host = container.read(editorHostProvider);
    expect(container.read(currentWorkspaceProvider).id, folder.id);
    final folderDoc = await waitForPage(
      tester,
      container,
      'src/app.js',
      restoreFolderText,
    );
    var documents = container.read(documentControllerProvider);
    expect(documents.openPaths, ['src/app.js']);
    expect(documents.activePath, 'src/app.js');
    expect(
      documents.active!.dirty,
      isTrue,
      reason: 'restored edits stay unsaved',
    );
    expect(documents.active!.savedText, gateFixture['src/app.js']);
    expect(host.textOf(folderDoc), restoreFolderText);

    // Its expanded folders, in the explorer.
    await pumpUntil(tester, () {
      final view = container.read(explorerViewProvider);
      return view.loaded && view.workspaceId == folder.id;
    }, what: "the folder's explorer view");
    expect(container.read(explorerViewProvider).expanded, {
      '',
      ...restoreFolderExpanded,
    });
    await _showExplorer(tester);
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('tree_src/lib/util.js'))
          .evaluate()
          .isNotEmpty,
      what: 'src/lib/util.js in the expanded tree',
    );
    await _hideExplorer(tester);

    // Home's recents: both workspaces, the folder first, both available.
    await tester.tap(find.byKey(const ValueKey('workbench_home')));
    await tester.pumpAndSettle();
    final folderEntry = find.byKey(ValueKey('recent_${folder.id}'));
    final demoEntry = find.byKey(const ValueKey('recent_demo'));
    bool available(Finder entry) => find
        .descendant(of: entry, matching: find.text('available'))
        .evaluate()
        .isNotEmpty;
    await pumpUntil(
      tester,
      () => available(folderEntry) && available(demoEntry),
      what: 'the recents with both workspaces available',
    );
    expect(
      tester.getTopLeft(folderEntry).dy,
      lessThan(tester.getTopLeft(demoEntry).dy),
    );

    // The project: two tabs, app.py active with its unsaved text.
    await tester.ensureVisible(demoEntry);
    await tester.pumpAndSettle();
    await tester.tap(demoEntry);
    await tester.pumpAndSettle();
    final demoDoc = await waitForPage(
      tester,
      container,
      'app.py',
      restoreDemoText,
    );
    documents = container.read(documentControllerProvider);
    expect(container.read(currentWorkspaceProvider).id, demoWorkspaceId);
    expect(documents.openPaths, ['main.js', 'app.py']);
    expect(documents.activePath, 'app.py');
    expect(documents.active!.language, 'python');
    expect(documents.active!.dirty, isTrue);
    expect(documents.active!.savedText, DemoWorkspace.files['app.py']);
    expect(host.textOf(demoDoc), restoreDemoText);

    // Its expanded folders and the explorer's scroll.
    await pumpUntil(tester, () {
      final view = container.read(explorerViewProvider);
      return view.loaded && view.workspaceId == demoWorkspaceId;
    }, what: "the project's explorer view");
    final demoView = container.read(explorerViewProvider);
    expect(demoView.expanded, {'', ...restoreDemoExpanded});
    expect(demoView.restoreOffset, restoreDemoScroll);
    await _showExplorer(tester);
    double? treeOffset() {
      final tree = find.byKey(const ValueKey('explorer_tree'));
      if (tree.evaluate().isEmpty) {
        return null;
      }
      final controller = tester.widget<ListView>(tree).controller;
      return controller != null && controller.hasClients
          ? controller.offset
          : null;
    }

    await pumpUntil(
      tester,
      () => treeOffset() == restoreDemoScroll,
      what: 'the explorer to scroll back to $restoreDemoScroll',
    );
    // The explorer jumps in a frame's callback, so the offset is there at
    // once but the rows move at the next frame's layout.
    await tester.pump();
    // Rows are 48 dp, and only those on screen are built (Phase 3 W4): at
    // 480 the eleventh row, docs/note_09.md (the first is docs itself),
    // is at the top of the tree.
    final topNote = find.byKey(const ValueKey('tree_docs/note_09.md'));
    expect(topNote, findsOneWidget);
    expect(
      tester.getTopLeft(topNote).dy,
      moreOrLessEquals(
        tester.getTopLeft(find.byKey(const ValueKey('explorer_tree'))).dy,
        epsilon: 0.5,
      ),
    );
    await _hideExplorer(tester);

    // Back to the folder: its unsaved text is still there, and only there:
    // the file on disk is as the host pushed it.
    await _openRecent(tester, folder.id);
    await waitForPage(tester, container, 'src/app.js', restoreFolderText);
    expect(container.read(documentControllerProvider).active!.dirty, isTrue);
    expect(await gate.disk('src/app.js'), sha256Of(gateFixture['src/app.js']!));
    gate.done();
    debugPrint(
      'restore-gate: the folder, its unsaved text and expanded folders came '
      'back; the project kept its tabs, unsaved text and explorer scroll',
    );

    // The log file survived the kill: part A's last record comes before
    // this session's marker, so it was on disk before the process died.
    final log = await startFileLog(appLogger);
    expect(log, isNotNull, reason: 'the log file did not open');
    final text = await log!.readRecent(maxBytes: 4 << 20);
    final marker = text.indexOf(restoreLogMarker);
    final session = text.lastIndexOf(log.marker!);
    expect(marker, isNonNegative, reason: "part A's record is not on disk");
    expect(marker, lessThan(session));
    expect(text, contains('[error] gate/log_marker'));
    debugPrint(
      'restore-gate: log file ${text.length} chars, part A record at '
      '$marker, this session from $session',
    );
  });
}
