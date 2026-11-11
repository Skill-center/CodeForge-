/// FileOperations (Phase 3 W4, gate G3): the explorer's operations over an
/// in-memory workspace, and how the open documents follow them. A rename or
/// a move keeps each editor document (so its undo history), its unsaved
/// text and its journal, now under the new path, through a process death
/// too. A delete closes clean tabs and keeps unsaved ones, marked deleted
/// on disk, until Save writes them again. Plain tests in real time.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/explorer_view_controller.dart';
import 'package:codeforge/application/file_operations.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/application/workspace_controller.dart';
import 'package:codeforge/core/editor/journal.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/memory_file_service.dart';

/// One app's worth of providers over [files] and [sessions]: a second world
/// over the same stores is the app after a restart.
final class _World {
  _World({MemoryFileService? files, SessionStore? sessions})
    : files = files ?? MemoryFileService(),
      sessions = sessions ?? MemorySessionStore() {
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        shellStateStoreProvider.overrideWithValue(InMemoryShellStateStore()),
        fileServiceProvider.overrideWithValue(this.files),
        sessionStoreProvider.overrideWithValue(this.sessions),
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final MemoryFileService files;
  final SessionStore sessions;
  final List<FakeEditorSurface> pages = [];
  late final ProviderContainer container;

  DocumentController get documents =>
      container.read(documentControllerProvider.notifier);

  DocumentsState get state => container.read(documentControllerProvider);

  FileOperations get operations => container.read(fileOperationsProvider);

  FakeEditorSurface get page => pages.single;

  OpenDocument doc(String path) => state.documents[path]!;

  /// The editor's text of the document at [path].
  String textOf(String path) => page.documents[doc(path).docId]!.text;

  /// Opens the workspace and starts the editor page.
  Future<void> start() async {
    // The shell, and with it the open workspace, as a cold start has them.
    container.read(shellControllerProvider);
    await container.read(workspaceControllerProvider.notifier).open();
    await container.read(editorHostProvider).start();
    await _drain();
  }

  /// The stored journals, once every write asked for has landed.
  Future<List<JournalEntry>> journal() async {
    await documents.persisted;
    return (await sessions.loadJournal('demo')).valueOrNull!;
  }

  /// The stored tabs' paths, once every write asked for has landed.
  Future<List<String>> savedTabs() async {
    await documents.persisted;
    return [
      for (final tab in (await sessions.loadTabs('demo')).valueOrNull!)
        tab.path,
    ];
  }
}

/// Lets streams and microtasks run.
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String _replayed(JournalEntry entry) => replayJournal(
  text: entry.snapshot.text,
  version: entry.snapshot.version,
  changes: entry.changes,
).text;

Matcher _fails(FileProblem problem) =>
    isA<FileFailure>().having((f) => f.problem, 'problem', problem);

void main() {
  group('rename and move', () {
    test('a rename keeps the editor document, its unsaved text and its '
        'journal, and highlights it for the new name', () async {
      final w = _World();
      await w.start();
      await w.documents.open('src/notes.txt');
      await _drain();
      final docId = w.doc('src/notes.txt').docId;
      w.page.typeText('print("hi")\n');
      await _drain();
      final text = w.textOf('src/notes.txt');

      final renamed = await w.operations.rename('src/notes.txt', 'hello.py');
      expect(renamed.orThrow, 'src/hello.py');
      await _drain();

      expect(w.state.openPaths, ['src/hello.py']);
      expect(w.state.activePath, 'src/hello.py');
      final doc = w.doc('src/hello.py');
      expect(doc.docId, docId, reason: 'the same editor document: undo stays');
      expect(doc.dirty, isTrue);
      expect(doc.language, 'python');
      expect(w.page.documents[docId]!.language, 'python');
      expect(w.page.documents[docId]!.text, text);
      expect(w.files.exists('src/notes.txt'), isFalse);
      expect(w.files.textOf('src/hello.py'), 'Scratch notes live here.\n');
      final journal = await w.journal();
      expect(journal.single.path, 'src/hello.py');
      expect(journal.single.snapshot.language, 'python');
      expect(_replayed(journal.single), text);
      expect(await w.savedTabs(), ['src/hello.py']);

      // Typing goes on in the journal under the new name.
      w.page.typeText('print(2)\n', docId: docId);
      await _drain();
      final after = await w.journal();
      expect(after.single.path, 'src/hello.py');
      expect(_replayed(after.single), w.textOf('src/hello.py'));
    });

    test('after a rename and a process death, the unsaved text comes back '
        'under the new name', () async {
      final files = MemoryFileService();
      final sessions = MemorySessionStore();
      final first = _World(files: files, sessions: sessions);
      await first.start();
      await first.documents.open('utils.js');
      await _drain();
      first.page.typeText('// mine\n');
      await _drain();
      expect(
        (await first.operations.rename('utils.js', 'helpers.js')).isOk,
        isTrue,
      );
      first.page.typeText('// more\n', docId: first.doc('helpers.js').docId);
      await _drain();
      final text = first.textOf('helpers.js');
      await first.documents.persisted;
      first.container.dispose();

      final second = _World(files: files, sessions: sessions);
      await second.start();
      await second.documents.restoreTabs();
      await _drain();
      expect(second.state.openPaths, ['helpers.js']);
      final doc = second.doc('helpers.js');
      expect(doc.dirty, isTrue);
      expect(doc.conflict, isNull);
      expect(second.textOf('helpers.js'), text);
    });

    test('a folder moves with its open documents, its expanded folders and '
        'its journal', () async {
      final w = _World();
      await w.start();
      final view = w.container.read(explorerViewProvider.notifier)
        ..toggle('src');
      await w.container.read(workspaceControllerProvider.notifier).load('src');
      await w.documents.open('src/greeting.dart');
      await w.documents.open('src/notes.txt');
      await _drain();
      w.page.typeText('more\n', docId: w.doc('src/notes.txt').docId);
      await _drain();

      expect((await w.operations.createFolder('lib')).isOk, isTrue);
      expect((await w.operations.move('src', 'lib')).orThrow, 'lib/src');
      await _drain();

      expect(w.state.openPaths, ['lib/src/greeting.dart', 'lib/src/notes.txt']);
      expect(w.state.activePath, 'lib/src/notes.txt');
      expect(w.doc('lib/src/notes.txt').dirty, isTrue);
      expect(w.doc('lib/src/greeting.dart').dirty, isFalse);
      expect(w.doc('lib/src/greeting.dart').language, 'dart');
      expect((await w.journal()).single.path, 'lib/src/notes.txt');
      expect(await w.savedTabs(), [
        'lib/src/greeting.dart',
        'lib/src/notes.txt',
      ]);
      final expanded = w.container.read(explorerViewProvider).expanded;
      expect(expanded, contains('lib/src'));
      expect(expanded, isNot(contains('src')));
      expect(
        w.container.read(workspaceControllerProvider).listings.keys,
        isNot(contains('src')),
      );
      expect(view.offset, 0);
    });

    test('a failed rename or move changes nothing', () async {
      final w = _World();
      await w.start();
      await w.documents.open('main.js');
      await _drain();
      w.files.failNextChange = const FileFailure(
        'The disk is full.',
        problem: FileProblem.io,
      );
      expect(
        (await w.operations.rename('main.js', 'app.js')).failureOrNull,
        _fails(FileProblem.io),
      );
      expect(
        (await w.operations.rename('main.js', 'utils.js')).failureOrNull,
        _fails(FileProblem.exists),
      );
      expect(w.state.openPaths, ['main.js']);
      expect(w.files.textOf('utils.js'), isNotNull);
      expect(w.files.exists('main.js'), isTrue);
    });

    test('a tab kept for a deleted file holds its name: nothing moves '
        'there', () async {
      final w = _World();
      await w.start();
      await w.documents.open('utils.js');
      await _drain();
      w.page.typeText('// keep me\n');
      await _drain();
      expect((await w.operations.delete('utils.js')).isOk, isTrue);
      expect(w.doc('utils.js').deletedOnDisk, isTrue);

      final refused = await w.operations.rename('main.js', 'utils.js');
      expect(refused.failureOrNull, _fails(FileProblem.inUse));
      expect(w.files.exists('main.js'), isTrue);
      expect(w.files.exists('utils.js'), isFalse);
    });
  });

  group('delete', () {
    test('clean tabs close; unsaved ones stay, marked deleted, until Save '
        'writes them again', () async {
      final w = _World();
      await w.start();
      await w.documents.open('main.js');
      await w.documents.open('src/greeting.dart');
      await w.documents.open('src/notes.txt');
      await _drain();
      w.page.typeText('kept\n', docId: w.doc('src/notes.txt').docId);
      await _drain();
      final text = w.textOf('src/notes.txt');

      expect((await w.operations.delete('src')).isOk, isTrue);
      await _drain();

      expect(w.state.openPaths, ['main.js', 'src/notes.txt']);
      final kept = w.doc('src/notes.txt');
      expect(kept.deletedOnDisk, isTrue);
      expect(kept.dirty, isTrue);
      expect(w.textOf('src/notes.txt'), text);
      expect(w.files.exists('src'), isFalse);
      final journal = await w.journal();
      expect(journal.single.path, 'src/notes.txt');
      expect(journal.single.snapshot.baseDigest, isNull);
      expect(_replayed(journal.single), text);

      expect((await w.documents.save('src/notes.txt')).isOk, isTrue);
      expect(w.files.textOf('src/notes.txt'), text);
      expect(w.doc('src/notes.txt').deletedOnDisk, isFalse);
      expect(w.doc('src/notes.txt').dirty, isFalse);
      expect(await w.journal(), isEmpty);
    });

    test("a deleted folder's expanded folders and listings go", () async {
      final w = _World();
      await w.start();
      w.container.read(explorerViewProvider.notifier).toggle('src');
      await w.container.read(workspaceControllerProvider.notifier).load('src');
      expect((await w.operations.delete('src')).isOk, isTrue);
      expect(
        w.container.read(explorerViewProvider).expanded,
        isNot(contains('src')),
      );
      expect(
        w.container.read(workspaceControllerProvider).listings.keys,
        isNot(contains('src')),
      );
    });
  });

  group('create, duplicate and count', () {
    test('a new folder shows, its parents expanded', () async {
      final w = _World();
      await w.start();
      expect((await w.operations.createFolder('a/b')).isOk, isTrue);
      expect(w.files.isFolder('a/b'), isTrue);
      expect(w.container.read(explorerViewProvider).expanded, contains('a'));
      expect(
        (await w.operations.createFolder('a/b')).failureOrNull,
        _fails(FileProblem.exists),
      );
      expect((await w.operations.createFile('a/b/c.js')).isOk, isTrue);
      expect(w.state.activePath, 'a/b/c.js');
      expect(
        w.container.read(explorerViewProvider).expanded,
        containsAll(['a', 'a/b']),
      );
    });

    test('a duplicate takes the next free name', () async {
      final w = _World();
      await w.start();
      expect(
        (await w.operations.duplicate('main.js', isFolder: false)).orThrow,
        'main copy.js',
      );
      expect(
        (await w.operations.duplicate('main.js', isFolder: false)).orThrow,
        'main copy 2.js',
      );
      expect(w.files.textOf('main copy 2.js'), w.files.textOf('main.js'));
      expect(
        (await w.operations.duplicate('src', isFolder: true)).orThrow,
        'src copy',
      );
      expect(
        w.files.textOf('src copy/notes.txt'),
        'Scratch notes live here.\n',
      );
      expect(w.files.textOf('src/notes.txt'), 'Scratch notes live here.\n');
    });

    test("a folder's files are counted at every depth", () async {
      final w = _World();
      await w.start();
      w.files
        ..putText('src/deep/er/a.txt', 'a')
        ..putFolder('src/empty');
      final count = (await w.operations.countFiles('src')).orThrow;
      expect(count.files, 3);
      expect(count.complete, isTrue);
      expect((await w.operations.countFiles('src/empty')).orThrow.files, 0);
    });
  });
}
