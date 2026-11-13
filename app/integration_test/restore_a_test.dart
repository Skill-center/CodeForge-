/// Restore gate, part A (G5, and G3's tabs): establish a distinctive state —
/// light theme, workspace route, terminal half-open, a second tab active —
/// and let it persist (prefs for the shell, the app database for tabs). CI
/// force-stops the process after this test; restore_b_test verifies
/// survival.
///
/// Two workspaces since Phase 3 W3 (G5: "the last workspace, project or
/// folder, its tabs with unsaved text, expanded folders, the explorer
/// scroll, and the recents"). The demo project gets unsaved text in its
/// active tab, expanded folders and a scrolled explorer; then the gate
/// folder (/sdcard/Documents/cf-gate, pushed by the host) opens through
/// Android's real picker, which the host drives (integration_test/
/// folder_gate.dart), and gets unsaved text and expanded folders of its
/// own. The folder is the workspace open at the kill.
///
/// The log file too (Phase 3 W1, G6): part A opens it as bootstrap does and
/// ends with an error record, with no flush asked for, just before the
/// kill. Part B finds it before its own session's marker.
library;

import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/explorer_view_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/workspace_controller.dart';
import 'package:codeforge/core/editor/journal.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/logging/logger.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/logging/file_log_sink.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/drift_session_store.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_fixture.dart';
import 'folder_gate.dart';
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

/// The record part A logs last and part B looks for in the log file.
const String restoreLogMarker = 'restore-gate: logged just before the kill';

/// Typed into the demo project's app.py, never saved.
const String restoreDemoMarker = '# restore gate: unsaved in the project\n';

/// app.py as part A leaves it.
String get restoreDemoText =>
    restoreDemoMarker + DemoWorkspace.files['app.py']!;

/// Typed into the gate folder's src/app.js, never saved.
const String restoreFolderMarker = '// restore gate: unsaved in the folder\n';

/// src/app.js as part A leaves it.
String get restoreFolderText =>
    restoreFolderMarker + gateFixture['src/app.js']!;

/// The demo project's folders part A expands, and its explorer's scroll.
const Set<String> restoreDemoExpanded = {'src', 'docs'};
const double restoreDemoScroll = 480;

/// The files part A adds to the demo project, so its explorer can scroll.
const int restoreDemoNotes = 40;

/// The gate folder's folders part A expands.
const Set<String> restoreFolderExpanded = {'src', 'src/lib'};

/// Waits until the editor page shows [path] of the current workspace with
/// [text], and returns its document id.
Future<String> waitForPage(
  WidgetTester tester,
  ProviderContainer container,
  String path,
  String text,
) async {
  final host = container.read(editorHostProvider);
  String? docId() =>
      container.read(documentControllerProvider).documents[path]?.docId;
  await pumpUntil(
    tester,
    () {
      final id = docId();
      return id != null &&
          host.status.phase == EditorHostPhase.ready &&
          host.activeDocId == id &&
          host.textOf(id) == text;
    },
    what: '$path to show in the editor',
    timeout: const Duration(seconds: 60),
  );
  return docId()!;
}

/// Waits until the session store holds [path]'s unsaved [text] and its tab,
/// active, for [workspaceId].
Future<void> waitForJournal(
  WidgetTester tester,
  ProviderContainer container,
  String workspaceId,
  String path,
  String text,
) async {
  final store = container.read(sessionStoreProvider);
  final documents = container.read(documentControllerProvider.notifier);
  var stored = false;
  for (var attempt = 0; attempt < 50 && !stored; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
    await documents.persisted;
    final journal =
        (await store.loadJournal(workspaceId)).valueOrNull ??
        const <JournalEntry>[];
    final tabs =
        (await store.loadTabs(workspaceId)).valueOrNull ?? const <SavedTab>[];
    final entry = journal.where((e) => e.path == path).firstOrNull;
    final tab = tabs.where((t) => t.path == path).firstOrNull;
    stored =
        entry != null &&
        replayJournal(
              text: entry.snapshot.text,
              version: entry.snapshot.version,
              changes: entry.changes,
            ).text ==
            text &&
        tab != null &&
        tab.active;
  }
  expect(stored, isTrue, reason: '$path: the journal never held the edit');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('restore A: two workspaces, light theme, terminal half', (
    tester,
  ) async {
    final gate = await FolderGate.start();
    // A clean slate for every attempt: an infrastructure retry reuses the
    // installed app, whose session database and demo project would bring
    // the failed attempt's tabs and unsaved text back.
    final appFiles = await applicationFilesPath();
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$appFiles/$appDatabaseFileName$suffix');
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
    final demoFolder = Directory(await demoWorkspacePath());
    if (demoFolder.existsSync()) {
      demoFolder.deleteSync(recursive: true);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await pumpRealApp(
      tester,
      prefs,
      overrides: [
        // The picker opens inside the gate folder, as in the folders group.
        folderPickerStartProvider.overrideWithValue(gateFolderStartUri),
      ],
    );
    // As bootstrap does after the first frame.
    final log = await startFileLog(appLogger);
    expect(log, isNotNull, reason: 'the log file did not open');

    // Fresh state: dismiss welcome, enter workspace.
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    // Home's list may need to scroll to it (Phase 3 W3).
    await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();

    // A second tab, active: main.js opened on its own, app.py from here.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final host = container.read(editorHostProvider);
    await pumpUntil(
      tester,
      () => container.read(documentControllerProvider).isOpen('main.js'),
      what: 'main.js to open',
    );
    final opened = await container
        .read(documentControllerProvider.notifier)
        .open('app.py');
    expect(opened.isOk, isTrue);
    await tester.pumpAndSettle();

    // Unsaved text in the project's active tab, typed through the page.
    await waitForPage(
      tester,
      container,
      'app.py',
      DemoWorkspace.files['app.py']!,
    );
    expect((await host.insert(restoreDemoMarker)).isOk, isTrue);
    final demoDoc = await waitForPage(
      tester,
      container,
      'app.py',
      restoreDemoText,
    );
    expect(host.textOf(demoDoc), restoreDemoText);
    await waitForJournal(tester, container, 'demo', 'app.py', restoreDemoText);

    // A folder long enough to scroll through (docs, written behind the
    // app's back), expanded with src, and the explorer scrolled down it.
    for (var i = 0; i < restoreDemoNotes; i++) {
      final name = 'note_${i.toString().padLeft(2, '0')}.md';
      File('${demoFolder.path}/docs/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('# Note $i\n');
    }
    await container.read(workspaceControllerProvider.notifier).refresh();
    final demoView = container.read(explorerViewProvider.notifier);
    expect(container.read(explorerViewProvider).workspaceId, 'demo');
    for (final path in restoreDemoExpanded) {
      demoView.toggle(path);
    }
    demoView.setScroll(restoreDemoScroll);
    await demoView.flush();

    // Terminal half-open.
    await tester.tap(find.byKey(const ValueKey('terminal_toggle')));
    await tester.pumpAndSettle();

    // Let the debounced shell persist land (real timers on device).
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    // The gate folder, through Home's Open Folder and Android's picker.
    await tester.tap(find.byKey(const ValueKey('workbench_home')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('open_folder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open_folder')));
    await tester.pump();
    expect(
      await gate.ask(
        'pick $gateFolderName',
        timeout: const Duration(seconds: 240),
      ),
      'picked',
    );
    await pumpUntil(
      tester,
      () =>
          container.read(currentWorkspaceProvider) is FolderLocation &&
          find.byKey(const ValueKey('terminal_toggle')).evaluate().isNotEmpty,
      what: 'the picked folder to open in the workbench',
      timeout: const Duration(seconds: 60),
    );
    final folder = container.read(currentWorkspaceProvider) as FolderLocation;
    expect(folder.name, gateFolderName);

    // Unsaved text in the folder's file, typed through the page, once the
    // workbench has reopened the folder's (empty) session.
    await tester.pumpAndSettle();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final inFolder = await container
        .read(documentControllerProvider.notifier)
        .open('src/app.js');
    expect(inFolder.isOk, isTrue);
    await tester.pumpAndSettle();
    await waitForPage(
      tester,
      container,
      'src/app.js',
      gateFixture['src/app.js']!,
    );
    expect((await host.insert(restoreFolderMarker)).isOk, isTrue);
    await waitForPage(tester, container, 'src/app.js', restoreFolderText);
    await waitForJournal(
      tester,
      container,
      folder.id,
      'src/app.js',
      restoreFolderText,
    );

    // The folder's own expanded folders.
    final folderView = container.read(explorerViewProvider.notifier);
    expect(container.read(explorerViewProvider).workspaceId, folder.id);
    for (final path in restoreFolderExpanded) {
      folderView.toggle(path);
    }
    await folderView.flush();

    // Light theme via settings.
    await tester.tap(find.byKey(const ValueKey('palette_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('palette_input')),
      'light',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('palette_theme.light')));
    await tester.pumpAndSettle();
    // The palette executes setThemeMode without awaiting it; give the
    // platform channel time to flush the write to disk before CI force-stops
    // the process (reading prefs here would only see the in-memory cache).
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();

    final reloaded = await SharedPreferences.getInstance();
    final settingsRaw = reloaded.getString(settingsStorageKey);
    final shellRaw = reloaded.getString(shellStateStorageKey);
    expect(settingsRaw, contains('"themeMode":"light"'));
    expect(shellRaw, contains('"lastRoute":"/workspace"'));
    expect(shellRaw, contains('"terminalStop":"half"'));
    // The open workspace is the folder (its tree URI is a grant's opaque
    // token: the envelope is app-private, docs/SECURITY.md §4.1).
    final remembered = decodeShellState(shellRaw).workspace;
    expect(remembered, isA<FolderLocation>());
    expect(remembered?.id, folder.id);

    // Tabs, unsaved text, views and the recents live in the app database
    // (ADR-0008), not the envelope: wait for every write asked for, then
    // read them back.
    await container.read(documentControllerProvider.notifier).persisted;
    final store = container.read(sessionStoreProvider);
    final tabs =
        (await store.loadTabs('demo')).valueOrNull ?? const <SavedTab>[];
    expect([for (final tab in tabs) tab.path], ['main.js', 'app.py']);
    expect(
      [
        for (final tab in tabs)
          if (tab.active) tab.path,
      ],
      ['app.py'],
    );
    expect(shellRaw, isNot(contains('main.js')));
    final folderTabs =
        (await store.loadTabs(folder.id)).valueOrNull ?? const <SavedTab>[];
    expect([for (final tab in folderTabs) tab.path], ['src/app.js']);
    expect((await store.loadJournal('demo')).valueOrNull?.map((e) => e.path), [
      'app.py',
    ]);
    expect(
      (await store.loadJournal(folder.id)).valueOrNull?.map((e) => e.path),
      ['src/app.js'],
    );
    final demoStored = (await store.loadView('demo')).valueOrNull;
    expect(demoStored?.expanded, restoreDemoExpanded);
    expect(demoStored?.scrollOffset, restoreDemoScroll);
    final folderStored = (await store.loadView(folder.id)).valueOrNull;
    expect(folderStored?.expanded, restoreFolderExpanded);
    final recents =
        (await store.loadWorkspaces()).valueOrNull ?? const <WorkspaceRecord>[];
    expect([for (final r in recents.take(2)) r.id], [folder.id, 'demo']);
    expect(recents.first.kind, WorkspaceKind.folder);
    debugPrint(
      'restore-gate: part A left the folder open with ${folderTabs.length} '
      'tab, unsaved text in both workspaces, ${recents.length} recents',
    );

    gate.done();

    // Last: an error record, and nothing that writes it out but the sink
    // itself. CI force-stops the process right after this test.
    appLogger.error('gate', 'log_marker', fields: {'note': restoreLogMarker});
  });
}
