/// The explorer's operations on the emulator (Phase 3 W4, gate G3), on
/// both kinds of workspace: the demo project in the app's own storage, then
/// the gate folder on shared storage, picked in Android's real folder
/// picker and reached through Android's real storage provider.
///
/// Each operation runs through FileOperations, as the explorer's menu runs
/// it, and is checked on disk: the project's with dart:io, the folder's by
/// the host (`FOLDERGATE disk|list`, integration_test/folder_gate.dart).
/// On each workspace:
/// - new folder and new file; rename, a case-only rename, move, duplicate
///   (a folder, so copying too) and delete;
/// - a taken name never overwrites: the operation fails and both files are
///   as they were;
/// - an open document with unsaved text follows its renamed folder and its
///   move: same editor document (so its undo history), same text, and its
///   journal row under the new path in the app database;
/// - deleting a clean open file closes its tab; deleting the folder of a
///   file with unsaved text keeps the tab, marked deleted on disk, and Save
///   writes the file again.
/// Then one rename through the explorer's real menu and dialog, in the
/// folder; and a file saved through Android's create-document picker (the
/// broker's `saveDocument`, which About → Recent logs → Save uses), driven
/// by the host (`FOLDERGATE save`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/file_operations.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/storage/drift_session_store.dart'
    show appDatabaseFileName;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_fixture.dart';
import 'folder_gate.dart';
import 'restore_a_test.dart' show waitForJournal, waitForPage;
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

/// Typed into a file of each workspace, never saved until the end.
const String explorerMarker = '// explorer gate: unsaved\n';

/// The file the create-document picker saves into the gate folder.
const String explorerSavedName = 'cf-gate-log.txt';

/// What is at [path] under [root] on disk: the file's SHA-256, `dir`, or
/// `absent`, as the host answers for the gate folder.
String _onDisk(String root, String path) {
  final full = '$root/$path';
  if (Directory(full).existsSync()) {
    return 'dir';
  }
  final file = File(full);
  return file.existsSync()
      ? sha256.convert(file.readAsBytesSync()).toString()
      : 'absent';
}

/// The names in [folder] under [root], sorted.
List<String> _namesOnDisk(String root, String folder) {
  final names = [
    for (final entity in Directory('$root/$folder').listSync())
      entity.uri.pathSegments.where((s) => s.isNotEmpty).last,
  ];
  return names..sort();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'explorer: every operation on a project and a folder, checked on disk',
    timeout: const Timeout(Duration(minutes: 10)),
    (tester) async {
      final gate = await FolderGate.start();
      // A clean slate, as in the restore pair: no session database, no
      // demo project from an earlier attempt.
      final appFiles = await applicationFilesPath();
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$appFiles/$appDatabaseFileName$suffix');
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
      final root = await demoWorkspacePath();
      if (Directory(root).existsSync()) {
        Directory(root).deleteSync(recursive: true);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await pumpRealApp(
        tester,
        prefs,
        overrides: [
          folderPickerStartProvider.overrideWithValue(gateFolderStartUri),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('explore_demo')));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(CodeForgeApp)),
        listen: false,
      );
      final host = container.read(editorHostProvider);
      final documents = container.read(documentControllerProvider.notifier);
      final operations = container.read(fileOperationsProvider);
      DocumentsStateView docs() =>
          DocumentsStateView(container.read(documentControllerProvider));
      await pumpUntil(
        tester,
        () =>
            docs().state.isOpen('main.js') &&
            host.status.phase == EditorHostPhase.ready,
        what: 'the demo project and the editor page',
        timeout: const Duration(seconds: 60),
      );

      // ── The project: the app's own storage, checked with dart:io ──────
      final greeting = DemoWorkspace.files['src/greeting.dart']!;
      final edited = explorerMarker + greeting;

      expect((await operations.createFolder('gate/made')).isOk, isTrue);
      expect(_onDisk(root, 'gate/made'), 'dir');
      expect((await operations.createFile('gate/made/new.js')).isOk, isTrue);
      expect(_onDisk(root, 'gate/made/new.js'), sha256Of(''));
      expect(docs().state.isOpen('gate/made/new.js'), isTrue);

      // Unsaved text in src/greeting.dart, in the journal.
      expect((await documents.open('src/greeting.dart')).isOk, isTrue);
      await tester.pumpAndSettle();
      await waitForPage(tester, container, 'src/greeting.dart', greeting);
      expect((await host.insert(explorerMarker)).isOk, isTrue);
      final docId = await waitForPage(
        tester,
        container,
        'src/greeting.dart',
        edited,
      );
      await waitForJournal(tester, container, 'demo', 'src/greeting.dart', edited);

      // Rename its folder: the document follows, unsaved, journal and all.
      expect((await operations.rename('src', 'source')).orThrow, 'source');
      expect(_onDisk(root, 'src'), 'absent');
      expect(_onDisk(root, 'source/greeting.dart'), sha256Of(greeting));
      docs().expectFollowed('source/greeting.dart', docId, host, edited);
      await waitForJournal(
        tester,
        container,
        'demo',
        'source/greeting.dart',
        edited,
      );

      // A rename that changes only the case.
      expect((await operations.rename('README.md', 'Readme.md')).isOk, isTrue);
      final rootNames = _namesOnDisk(root, '');
      expect(rootNames, contains('Readme.md'));
      expect(rootNames, isNot(contains('README.md')));

      // Move the document's file.
      expect(
        (await operations.move('source/greeting.dart', 'gate/made')).orThrow,
        'gate/made/greeting.dart',
      );
      expect(_onDisk(root, 'source/greeting.dart'), 'absent');
      expect(_onDisk(root, 'gate/made/greeting.dart'), sha256Of(greeting));
      docs().expectFollowed('gate/made/greeting.dart', docId, host, edited);

      // Duplicate a folder: a copy beside it, with what is in it.
      expect(
        (await operations.duplicate('gate/made', isFolder: true)).orThrow,
        'gate/made copy',
      );
      expect(_onDisk(root, 'gate/made copy/new.js'), sha256Of(''));
      expect(
        _onDisk(root, 'gate/made copy/greeting.dart'),
        sha256Of(greeting),
      );

      // Taken names: nothing is overwritten.
      final mainJs = sha256Of(DemoWorkspace.files['main.js']!);
      final utilsJs = sha256Of(DemoWorkspace.files['utils.js']!);
      expect(
        (await operations.rename('main.js', 'utils.js')).failureOrNull,
        failsWith(FileProblem.exists),
      );
      expect(
        (await operations.move('gate/made copy/new.js', 'gate/made'))
            .failureOrNull,
        failsWith(FileProblem.exists),
      );
      expect(_onDisk(root, 'main.js'), mainJs);
      expect(_onDisk(root, 'utils.js'), utilsJs);
      expect(_onDisk(root, 'gate/made copy/new.js'), sha256Of(''));

      // Delete a clean open file: its tab closes.
      expect((await documents.open('utils.js')).isOk, isTrue);
      await tester.pumpAndSettle();
      expect((await operations.delete('utils.js')).isOk, isTrue);
      expect(_onDisk(root, 'utils.js'), 'absent');
      expect(docs().state.isOpen('utils.js'), isFalse);

      // Delete the folder of the file with unsaved text: its tab stays,
      // deleted on disk, and Save writes it again.
      expect((await operations.delete('gate/made')).isOk, isTrue);
      expect(_onDisk(root, 'gate/made'), 'absent');
      docs().expectDeletedOnDisk('gate/made/greeting.dart');
      expect((await documents.save('gate/made/greeting.dart')).isOk, isTrue);
      expect(_onDisk(root, 'gate/made/greeting.dart'), sha256Of(edited));
      expect(
        docs().state.documents['gate/made/greeting.dart']!.deletedOnDisk,
        isFalse,
      );
      expect((await operations.delete('gate/made copy')).isOk, isTrue);
      expect(_onDisk(root, 'gate/made copy'), 'absent');
      debugPrint('explorer gate: project done');

      // ── The folder: Android's picker and provider, checked by the host ─
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
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final appJs = gateFixture['src/app.js']!;
      final appEdited = explorerMarker + appJs;

      expect((await operations.createFolder('made')).isOk, isTrue);
      expect(await gate.disk('made'), 'dir');
      expect((await operations.createFile('made/new.js')).isOk, isTrue);
      expect(await gate.disk('made/new.js'), sha256Of(''));
      // A taken name, case ignored by this storage: refused, and nothing
      // is made or changed.
      expect(
        (await operations.createFile('HELLO.TXT')).failureOrNull,
        failsWith(FileProblem.exists),
      );
      expect(await gate.names(''), 'Readme.md,hello.txt,made,notes,src');
      expect(
        await gate.disk('hello.txt'),
        sha256Of(gateFixture['hello.txt']!),
      );

      expect((await documents.open('src/app.js')).isOk, isTrue);
      await tester.pumpAndSettle();
      await waitForPage(tester, container, 'src/app.js', appJs);
      expect((await host.insert(explorerMarker)).isOk, isTrue);
      final appDoc = await waitForPage(
        tester,
        container,
        'src/app.js',
        appEdited,
      );
      await waitForJournal(tester, container, folder.id, 'src/app.js', appEdited);

      expect((await operations.rename('src', 'source')).orThrow, 'source');
      expect(await gate.disk('src'), 'absent');
      expect(await gate.disk('source/app.js'), sha256Of(appJs));
      expect(
        await gate.disk('source/lib/util.js'),
        sha256Of(gateFixture['src/lib/util.js']!),
      );
      docs().expectFollowed('source/app.js', appDoc, host, appEdited);
      await waitForJournal(
        tester,
        container,
        folder.id,
        'source/app.js',
        appEdited,
      );

      expect((await operations.rename('Readme.md', 'README.md')).isOk, isTrue);
      expect(await gate.names(''), 'README.md,hello.txt,made,notes,source');

      expect(
        (await operations.move('source/app.js', 'made')).orThrow,
        'made/app.js',
      );
      expect(await gate.disk('source/app.js'), 'absent');
      expect(await gate.disk('made/app.js'), sha256Of(appJs));
      docs().expectFollowed('made/app.js', appDoc, host, appEdited);

      // The host's paths have no spaces: the copy is checked under another
      // name, which renames it too.
      expect(
        (await operations.duplicate('made', isFolder: true)).orThrow,
        'made copy',
      );
      expect(
        await gate.names(''),
        'README.md,hello.txt,made,made?copy,notes,source',
      );
      expect(
        (await operations.rename('made copy', 'made-copy')).orThrow,
        'made-copy',
      );
      expect(await gate.disk('made-copy/new.js'), sha256Of(''));
      expect(await gate.disk('made-copy/app.js'), sha256Of(appJs));

      expect(
        (await operations.rename('hello.txt', 'notes')).failureOrNull,
        failsWith(FileProblem.exists),
      );
      expect(
        (await operations.move('made-copy/new.js', 'made')).failureOrNull,
        failsWith(FileProblem.exists),
      );
      expect(
        await gate.disk('hello.txt'),
        sha256Of(gateFixture['hello.txt']!),
      );
      expect(await gate.disk('made-copy/new.js'), sha256Of(''));

      expect((await documents.open('notes/todo.md')).isOk, isTrue);
      await tester.pumpAndSettle();
      expect((await operations.delete('notes/todo.md')).isOk, isTrue);
      expect(await gate.disk('notes/todo.md'), 'absent');
      expect(docs().state.isOpen('notes/todo.md'), isFalse);

      expect((await operations.delete('made')).isOk, isTrue);
      expect(await gate.disk('made'), 'absent');
      docs().expectDeletedOnDisk('made/app.js');
      expect((await documents.save('made/app.js')).isOk, isTrue);
      expect(await gate.disk('made/app.js'), sha256Of(appEdited));
      expect((await operations.delete('made-copy')).isOk, isTrue);
      expect(await gate.disk('made-copy'), 'absent');
      debugPrint('explorer gate: folder done');

      // ── One rename through the explorer's own menu and dialog ─────────
      await tester.tap(find.byKey(const ValueKey('activity_explorer')));
      await pumpUntil(
        tester,
        () => find.byKey(const ValueKey('tree_hello.txt')).evaluate().isNotEmpty,
        what: 'hello.txt in the explorer',
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('tree_hello.txt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('explorer_menu_rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('name_field')),
        'greeting.txt',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('name_confirm')));
      await pumpUntil(
        tester,
        () =>
            find.byKey(const ValueKey('tree_greeting.txt')).evaluate().isNotEmpty,
        what: 'the renamed row',
      );
      expect(await gate.disk('hello.txt'), 'absent');
      expect(
        await gate.disk('greeting.txt'),
        sha256Of(gateFixture['hello.txt']!),
      );
      if (find.byType(DraggableScrollableSheet).evaluate().isNotEmpty) {
        await tester.tapAt(const Offset(200, 40));
        await tester.pumpAndSettle();
      }

      // ── A file through Android's create-document picker ───────────────
      final broker = container.read(storageBrokerProvider);
      final text =
          'CodeForge explorer gate, saved through the picker at '
          '${DateTime.now().toUtc().toIso8601String()}\n';
      final saving = broker.saveDocument(
        suggestedName: explorerSavedName,
        mimeType: 'text/plain',
        bytes: utf8.encode(text),
        initialUri: gateFolderStartUri,
      );
      expect(
        await gate.ask(
          'save $explorerSavedName',
          timeout: const Duration(seconds: 240),
        ),
        'saved',
      );
      expect((await saving).orThrow, explorerSavedName);
      expect(await gate.disk(explorerSavedName), sha256Of(text));
      debugPrint('explorer gate: saved through the picker');

      gate.done();
    },
  );
}

/// The documents as a test reads them.
final class DocumentsStateView {
  DocumentsStateView(this.state);

  final DocumentsState state;

  /// The document now at [path] is the one that was [docId], with its
  /// unsaved [text] still in the editor page.
  void expectFollowed(
    String path,
    String docId,
    EditorHost host,
    String text,
  ) {
    final doc = state.documents[path];
    expect(doc, isNotNull, reason: '$path is not open');
    expect(doc!.docId, docId, reason: '$path: another editor document');
    expect(doc.dirty, isTrue, reason: '$path lost its unsaved state');
    expect(host.textOf(docId), text, reason: '$path: the page text changed');
  }

  /// The document at [path] is still open, unsaved, marked deleted on disk.
  void expectDeletedOnDisk(String path) {
    final doc = state.documents[path];
    expect(doc, isNotNull, reason: '$path was closed');
    expect(doc!.deletedOnDisk, isTrue, reason: '$path: not deleted on disk');
    expect(doc.dirty, isTrue, reason: '$path lost its unsaved state');
  }
}
