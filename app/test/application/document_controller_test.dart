/// DocumentController (Phase 2 W4, W5, W7): open documents, tabs, dirty
/// state, save, Save As, New File, tab restore, the hot-exit journal and the
/// large-file policy, over an
/// in-memory workspace, an in-memory session store and the scripted editor
/// page. Plain tests in real time.
library;

import 'dart:convert';

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/application/workbench_intents.dart';
import 'package:codeforge/application/workspace_controller.dart';
import 'package:codeforge/core/editor/journal.dart';
import 'package:codeforge/core/editor/languages.dart';
import 'package:codeforge/core/editor/large_files.dart';
import 'package:codeforge/core/editor/protocol.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/flaky_session_store.dart';
import '../support/memory_file_service.dart';

/// One app's worth of providers over [files], [shellStore] and [sessions]:
/// a second world over the same stores is the app after a restart.
final class _World {
  _World({
    MemoryFileService? files,
    InMemoryShellStateStore? shellStore,
    SessionStore? sessions,
  }) : files = files ?? MemoryFileService(),
       shellStore = shellStore ?? InMemoryShellStateStore(),
       sessions = sessions ?? MemorySessionStore() {
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        shellStateStoreProvider.overrideWithValue(this.shellStore),
        fileServiceProvider.overrideWithValue(this.files),
        sessionStoreProvider.overrideWithValue(this.sessions),
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final MemoryFileService files;
  final InMemoryShellStateStore shellStore;
  final SessionStore sessions;
  final List<FakeEditorSurface> pages = [];
  late final ProviderContainer container;

  DocumentController get documents =>
      container.read(documentControllerProvider.notifier);

  DocumentsState get state => container.read(documentControllerProvider);

  FakeEditorSurface get page => pages.single;

  OpenDocument doc(String path) => state.documents[path]!;

  /// Starts the editor page, so documents reach it.
  Future<void> startEditor() async {
    await container.read(editorHostProvider).start();
    await _drain();
  }

  /// Process death: nothing of this app runs or writes any more.
  void kill() => container.dispose();

  /// The saved tabs, once every write asked for has landed.
  Future<List<SavedTab>> savedTabs() async {
    await documents.persisted;
    return (await sessions.loadTabs('demo')).valueOrNull!;
  }

  /// The stored journals, once every write asked for has landed.
  Future<List<JournalEntry>> journal() async {
    await documents.persisted;
    return (await sessions.loadJournal('demo')).valueOrNull!;
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

/// The app after a restart over [files] and [sessions], its last session
/// reopened.
Future<_World> _restart(
  MemoryFileService files,
  SessionStore sessions, {
  String? fallback,
}) async {
  final w = _World(files: files, sessions: sessions);
  await w.startEditor();
  await w.documents.restoreTabs(fallback: fallback);
  await _drain();
  return w;
}

Matcher _fails(FileProblem problem) =>
    isA<FileFailure>().having((f) => f.problem, 'problem', problem);

void main() {
  group('opening', () {
    test('opens files into tabs; opening again activates', () async {
      final w = _World();
      expect((await w.documents.open('main.js')).isOk, isTrue);
      await w.documents.open('app.py');
      await w.documents.open('main.js');
      expect(w.state.openPaths, ['main.js', 'app.py']);
      expect(w.state.activePath, 'main.js');
      expect(w.doc('app.py').language, 'python');
      expect(w.doc('main.js').dirty, isFalse);
    });

    test('a double tap opens one tab', () async {
      final w = _World();
      await Future.wait([
        w.documents.open('app.py'),
        w.documents.open('app.py'),
      ]);
      expect(w.state.openPaths, ['app.py']);
    });

    test('refused files open no tab and say why', () async {
      final w = _World();
      w.files.putBytes('logo.png', [0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A]);
      w.files.putBytes('latin1.txt', [0x63, 0x61, 0x66, 0xE9]);
      expect(
        (await w.documents.open('logo.png')).failureOrNull,
        _fails(FileProblem.notText),
      );
      expect(
        (await w.documents.open('latin1.txt')).failureOrNull,
        _fails(FileProblem.notText),
      );
      expect(
        (await w.documents.open('ghost.js')).failureOrNull,
        _fails(FileProblem.notFound),
      );
      expect(w.state.openPaths, isEmpty);
    });

    test('a shebang names the language of a file without extension', () async {
      final w = _World();
      w.files.putText('tool/serve', '#!/usr/bin/env node\nconsole.log(1);\n');
      w.files.putText('tool/build', '#!/usr/bin/python3 -u\nprint(1)\n');
      await w.documents.open('tool/serve');
      await w.documents.open('tool/build');
      expect(w.doc('tool/serve').language, 'javascript');
      expect(w.doc('tool/build').language, 'python');
    });
  });

  group('tabs', () {
    test('closing the active tab falls back to the last one used', () async {
      final w = _World();
      await w.documents.open('main.js');
      await w.documents.open('app.py');
      await w.documents.open('utils.js');
      w.documents
        ..activate('main.js')
        ..activate('utils.js')
        // Most recent first: utils.js, main.js, app.py.
        ..close('utils.js');
      expect(w.state.activePath, 'main.js');
      w.documents.close('main.js');
      expect(w.state.activePath, 'app.py');
      w.documents.close('app.py');
      expect(w.state.activePath, isNull);
      expect(w.state.openPaths, isEmpty);
    });

    test('next and previous tab wrap around', () async {
      final w = _World();
      for (final path in ['main.js', 'app.py', 'utils.js']) {
        await w.documents.open(path);
      }
      w.documents.activateNeighbour(forward: true);
      expect(w.state.activePath, 'main.js');
      w.documents.activateNeighbour(forward: false);
      expect(w.state.activePath, 'utils.js');
    });

    test('twelve documents switch without mixing their text (G3)', () async {
      final w = _World();
      await w.startEditor();
      for (var i = 0; i < 12; i++) {
        w.files.putText('f$i.js', 'file $i\n');
      }
      for (var i = 0; i < 12; i++) {
        await w.documents.open('f$i.js');
      }
      await _drain();
      expect(w.state.openPaths, hasLength(12));
      expect(w.page.documents, hasLength(12));

      w.documents.activate('f3.js');
      await _drain();
      w.page.typeText('edit 3\n');
      await _drain();
      w.documents.activate('f7.js');
      await _drain();
      expect(w.page.activeDocId, w.doc('f7.js').docId);
      expect(w.state.dirtyPaths, ['f3.js']);
      final host = w.container.read(editorHostProvider);
      expect(host.textOf(w.doc('f3.js').docId), 'file 3\nedit 3\n');
      expect(host.textOf(w.doc('f7.js').docId), 'file 7\n');
    });

    test('closing a tab closes its document in the editor', () async {
      final w = _World();
      await w.startEditor();
      await w.documents.open('main.js');
      await w.documents.open('app.py');
      await _drain();
      final mainId = w.doc('main.js').docId;
      w.documents.close('app.py');
      await _drain();
      expect(w.page.documents.keys.toList(), [mainId]);
      expect(w.page.activeDocId, mainId);
    });
  });

  group('dirty and save', () {
    test('dirty compares with the saved text: undoing back is clean', () async {
      final w = _World();
      await w.startEditor();
      await w.documents.open('main.js');
      await _drain();
      w.page.typeText('// x');
      await _drain();
      expect(w.doc('main.js').dirty, isTrue);
      expect(w.state.dirtyPaths, ['main.js']);
      w.page.deleteText(4);
      await _drain();
      expect(w.doc('main.js').dirty, isFalse);
    });

    test('save keeps CRLF and the byte-order mark (G2)', () async {
      final w = _World();
      w.files.putText(
        'win.txt',
        'one\ntwo\n',
        format: const TextFormat(lineEnding: LineEnding.crlf, bom: true),
      );
      await w.startEditor();
      await w.documents.open('win.txt');
      await _drain();
      // The editor only ever sees "\n".
      expect(w.page.documents[w.doc('win.txt').docId]!.text, 'one\ntwo\n');
      w.page.typeText('three\n');
      await _drain();
      expect((await w.documents.save('win.txt')).isOk, isTrue);
      expect(w.files.bytesOf('win.txt'), [
        ...utf8Bom,
        ...utf8.encode('one\r\ntwo\r\nthree\r\n'),
      ]);
      expect(w.doc('win.txt').dirty, isFalse);
    });

    test('a file changed on disk is overwritten only when told', () async {
      final w = _World();
      await w.startEditor();
      await w.documents.open('main.js');
      await _drain();
      w.page.typeText('// mine\n');
      await _drain();
      w.files.putText('main.js', 'theirs\n');

      final refused = await w.documents.save('main.js');
      expect(refused.failureOrNull, _fails(FileProblem.changedOnDisk));
      expect(w.files.textOf('main.js'), 'theirs\n');
      expect(w.doc('main.js').dirty, isTrue);

      expect((await w.documents.save('main.js', overwrite: true)).isOk, isTrue);
      expect(w.files.textOf('main.js'), endsWith('// mine\n'));
      expect(w.doc('main.js').dirty, isFalse);
    });

    test('a failed write keeps the document dirty', () async {
      final w = _World();
      await w.startEditor();
      await w.documents.open('main.js');
      await _drain();
      final before = w.files.textOf('main.js');
      w.page.typeText('// unsaved\n');
      await _drain();
      w.files.failNextWrite = const FileFailure(
        'disk full',
        problem: FileProblem.io,
      );
      expect((await w.documents.save('main.js')).isOk, isFalse);
      expect(w.files.textOf('main.js'), before);
      expect(w.doc('main.js').dirty, isTrue);
    });

    test('typing that races a save stays unsaved, and dirty', () async {
      final w = _World();
      await w.startEditor();
      await w.documents.open('main.js');
      await _drain();
      w.page
        ..typeText('// one\n')
        ..typeAfterSnapshot = '// two\n';
      await _drain();
      await w.documents.save('main.js');
      await _drain();
      final onDisk = w.files.textOf('main.js')!;
      expect(onDisk, endsWith('// one\n'));
      expect(onDisk, isNot(contains('// two')));
      expect(w.doc('main.js').dirty, isTrue);
    });
  });

  group('save as and new file', () {
    test('save as moves the tab and re-highlights the same document', () async {
      final w = _World();
      final workspace = w.container.read(workspaceControllerProvider.notifier);
      await workspace.open();
      await workspace.load('src');
      await w.startEditor();
      await w.documents.open('src/notes.txt');
      await _drain();
      final docId = w.doc('src/notes.txt').docId;
      w.page.typeText('print("hi")\n');
      await _drain();

      final result = await w.documents.saveAs('src/notes.txt', 'src/hello.py');
      expect(result.isOk, isTrue);
      await _drain();
      expect(w.state.openPaths, ['src/hello.py']);
      expect(w.state.activePath, 'src/hello.py');
      final moved = w.doc('src/hello.py');
      expect(moved.docId, docId, reason: 'same editor document: undo stays');
      expect(moved.language, 'python');
      expect(moved.dirty, isFalse);
      expect(w.page.documents[docId]!.language, 'python');
      expect(
        w.files.textOf('src/hello.py'),
        'Scratch notes live here.\nprint("hi")\n',
      );
      expect(w.files.textOf('src/notes.txt'), 'Scratch notes live here.\n');
      expect(
        [for (final tab in await w.savedTabs()) tab.path],
        ['src/hello.py'],
      );
      // The explorer's listing of src/ shows the new file.
      await _drain();
      final src = w.container.read(workspaceControllerProvider).listings['src'];
      expect(src?.valueOrNull?.map((e) => e.name), contains('hello.py'));
    });

    test('save as asks before replacing, and refuses an open tab', () async {
      final w = _World();
      await w.documents.open('main.js');
      await w.documents.open('utils.js');
      expect(
        (await w.documents.saveAs('main.js', 'app.py')).failureOrNull,
        _fails(FileProblem.exists),
      );
      expect(
        (await w.documents.saveAs('main.js', 'utils.js')).failureOrNull,
        _fails(FileProblem.inUse),
      );
      expect(
        (await w.documents.saveAs('main.js', '../out.js')).failureOrNull,
        _fails(FileProblem.invalidPath),
      );
      final replaced = await w.documents.saveAs(
        'main.js',
        'app.py',
        overwrite: true,
      );
      expect(replaced.isOk, isTrue);
      expect(w.files.textOf('app.py'), w.files.textOf('main.js'));
      expect(w.state.openPaths, ['app.py', 'utils.js']);
    });

    test('new file creates an empty file and opens it', () async {
      final w = _World();
      expect((await w.documents.createFile('src/new.ts')).isOk, isTrue);
      expect(w.files.textOf('src/new.ts'), '');
      expect(w.state.activePath, 'src/new.ts');
      expect(w.doc('src/new.ts').language, 'typescript');
      expect(
        (await w.documents.createFile('src/new.ts')).failureOrNull,
        _fails(FileProblem.exists),
      );
      expect(
        (await w.documents.createFile('/abs.js')).failureOrNull,
        _fails(FileProblem.invalidPath),
      );
    });
  });

  group('restart', () {
    test('open tabs and the active one come back (G3)', () async {
      final files = MemoryFileService();
      final sessions = MemorySessionStore();
      final first = _World(files: files, sessions: sessions);
      await first.documents.open('main.js');
      await first.documents.open('app.py');
      await first.documents.open('README.md');
      first.documents.activate('app.py');
      final saved = await first.savedTabs();
      expect(
        [for (final tab in saved) tab.path],
        ['main.js', 'app.py', 'README.md'],
      );
      expect(
        [
          for (final tab in saved)
            if (tab.active) tab.path,
        ],
        ['app.py'],
      );
      // Tabs live in the session store now, not the shell envelope.
      expect(first.shellStore.load().openTabs, isEmpty);

      final second = _World(files: files, sessions: sessions);
      await second.documents.restoreTabs(fallback: 'main.js');
      expect(second.state.openPaths, ['main.js', 'app.py', 'README.md']);
      expect(second.state.activePath, 'app.py');
    });

    test('files that are gone are skipped; nothing open → fallback', () async {
      final w = _World(
        shellStore: InMemoryShellStateStore(
          const ShellState(
            openTabs: ['gone.js', 'app.py'],
            activeTab: 'gone.js',
          ),
        ),
      );
      await w.documents.restoreTabs(fallback: 'main.js');
      expect(w.state.openPaths, ['app.py']);
      expect(w.state.activePath, 'app.py');
      // A W4 build's tabs moved out of the envelope, once.
      expect(w.container.read(shellControllerProvider).openTabs, isEmpty);
      expect([for (final tab in await w.savedTabs()) tab.path], ['app.py']);

      final fresh = _World();
      await fresh.documents.restoreTabs(fallback: 'main.js');
      expect(fresh.state.openPaths, ['main.js']);
      // Once per run: closing everything and coming back opens nothing.
      fresh.documents.close('main.js');
      await fresh.documents.restoreTabs(fallback: 'main.js');
      expect(fresh.state.openPaths, isEmpty);
    });
  });

  group('hot-exit journal (G4)', () {
    test('unsaved edits are journaled: a snapshot, then each change', () async {
      final w = _World();
      await w.startEditor();
      await w.documents.open('main.js');
      await _drain();
      final saved = w.files.textOf('main.js')!;
      w.page.typeText('// one\n');
      await _drain();
      var entry = (await w.journal()).single;
      expect(entry.path, 'main.js');
      expect(entry.snapshot.text, '$saved// one\n');
      expect(entry.snapshot.baseDigest, textDigest(saved));
      expect(entry.changes, isEmpty);

      w.page
        ..typeText('// two\n')
        ..deleteText(3);
      await _drain();
      entry = (await w.journal()).single;
      expect(entry.changes, hasLength(2));
      final host = w.container.read(editorHostProvider);
      expect(_replayed(entry), host.textOf(w.doc('main.js').docId));
    });

    test('undone back to the saved text, saved or closed: it goes', () async {
      final w = _World();
      await w.startEditor();
      await w.documents.open('main.js');
      await _drain();
      w.page.typeText('x');
      await _drain();
      expect(await w.journal(), hasLength(1));
      w.page.deleteText(1);
      await _drain();
      expect(w.doc('main.js').dirty, isFalse);
      expect(await w.journal(), isEmpty);

      w.page.typeText('y');
      await _drain();
      expect((await w.documents.save('main.js')).isOk, isTrue);
      expect(await w.journal(), isEmpty);

      w.page.typeText('z');
      await _drain();
      expect(await w.journal(), hasLength(1));
      w.documents.close('main.js');
      expect(await w.journal(), isEmpty);
    });

    test('a tab switch and a checkpoint write fresh snapshots', () async {
      final w = _World();
      await w.startEditor();
      await w.documents.open('main.js');
      await w.documents.open('app.py');
      w.documents.activate('main.js');
      await _drain();
      final main = w.doc('main.js').docId;
      w.page
        ..typeText('a', docId: main)
        ..typeText('b', docId: main);
      await _drain();
      expect((await w.journal()).single.changes, hasLength(1));

      w.documents.activate('app.py');
      var entry = (await w.journal()).single;
      expect(entry.changes, isEmpty);
      expect(entry.snapshot.text, endsWith('ab'));

      w.page.typeText('c', docId: main);
      await _drain();
      expect((await w.journal()).single.changes, hasLength(1));
      await w.documents.checkpoint();
      entry = (await w.journal()).single;
      expect(entry.changes, isEmpty);
      expect(entry.snapshot.text, endsWith('abc'));
    });

    test('tabs keep the cursor and scroll the page reports', () async {
      final w = _World();
      await w.startEditor();
      await w.documents.open('main.js');
      await _drain();
      w.page
        ..moveCursor(2)
        ..moveCursor(4, head: 9, scrollTop: 64);
      await _drain();
      // One save covers a burst of reports, a second after the first.
      await Future<void>.delayed(
        DocumentController.viewStateSaveDelay +
            const Duration(milliseconds: 200),
      );
      final tab = (await w.savedTabs()).single;
      expect(
        [tab.selectionAnchor, tab.selectionHead, tab.scrollTop],
        [4, 9, 64],
      );
    });

    test('after process death: the same text, still unsaved, cursor and '
        'scroll back', () async {
      final files = MemoryFileService();
      final sessions = MemorySessionStore();
      final first = _World(files: files, sessions: sessions);
      await first.startEditor();
      await first.documents.open('main.js');
      await first.documents.open('app.py');
      await _drain();
      final py = first.doc('app.py').docId;
      first.page
        ..typeText('# unsaved\n', docId: py)
        ..typeText('x = 1', docId: py)
        ..moveCursor(3, head: 7, scrollTop: 40, docId: py);
      await _drain();
      final live = first.container.read(editorHostProvider).textOf(py);
      // No pause, no checkpoint: edits are journaled as they arrive, and
      // the cursor within a second.
      await Future<void>.delayed(
        DocumentController.viewStateSaveDelay +
            const Duration(milliseconds: 200),
      );
      await first.documents.persisted;
      first.kill();

      final second = await _restart(files, sessions, fallback: 'main.js');
      expect(second.state.openPaths, ['main.js', 'app.py']);
      expect(second.state.activePath, 'app.py');
      final doc = second.doc('app.py');
      expect(doc.dirty, isTrue);
      expect(doc.conflict, isNull);
      expect(doc.savedText, files.textOf('app.py'));
      expect(second.doc('main.js').dirty, isFalse);
      final host = second.container.read(editorHostProvider);
      expect(host.textOf(doc.docId), live);
      expect(second.page.documents[doc.docId]!.text, live);
      final view = host.viewStateOf(doc.docId);
      expect(
        [view?.selection?.anchor, view?.selection?.head, view?.scrollTop],
        [3, 7, 40],
      );

      // The journal goes on from the restored text.
      second.page.typeText('!', docId: doc.docId);
      await _drain();
      expect(_replayed((await second.journal()).single), '$live!');
    });

    test(
      'a file changed meanwhile keeps both texts until the user picks',
      () async {
        final files = MemoryFileService();
        final sessions = MemorySessionStore();
        final first = _World(files: files, sessions: sessions);
        await first.startEditor();
        await first.documents.open('app.py');
        await _drain();
        first.page.typeText('# mine\n');
        await _drain();
        final mine = first.container
            .read(editorHostProvider)
            .textOf(first.doc('app.py').docId);
        await first.documents.persisted;
        first.kill();
        files.putText('app.py', 'print("theirs")\n');

        // Unanswered, the question comes back after another restart.
        for (var run = 0; run < 2; run++) {
          final w = await _restart(files, sessions);
          final doc = w.doc('app.py');
          expect(doc.conflict, DocumentConflict.changedOnDisk, reason: '$run');
          expect(doc.dirty, isTrue);
          expect(doc.savedText, 'print("theirs")\n');
          expect(w.container.read(editorHostProvider).textOf(doc.docId), mine);
          expect(w.state.firstConflict, 'app.py');
          await w.documents.persisted;
          w.kill();
        }

        // Keeping my changes settles it: they are now unsaved changes to the
        // file as it is.
        final keep = await _restart(files, sessions);
        keep.documents.keepRestoredEdits('app.py');
        expect(keep.doc('app.py').conflict, isNull);
        expect(keep.doc('app.py').dirty, isTrue);
        expect(
          (await keep.journal()).single.snapshot.baseDigest,
          textDigest('print("theirs")\n'),
        );
        keep.kill();
        final after = await _restart(files, sessions);
        expect(after.doc('app.py').conflict, isNull);
        expect(after.doc('app.py').dirty, isTrue);
        expect((await after.documents.save('app.py')).isOk, isTrue);
        expect(files.textOf('app.py'), mine);
        expect(await after.journal(), isEmpty);
      },
    );

    test('using the file drops the restored changes', () async {
      final files = MemoryFileService();
      final sessions = MemorySessionStore();
      final first = _World(files: files, sessions: sessions);
      await first.startEditor();
      await first.documents.open('app.py');
      await _drain();
      first.page.typeText('# mine\n');
      await _drain();
      await first.documents.persisted;
      first.kill();
      files.putText('app.py', 'print("theirs")\n');

      final w = await _restart(files, sessions);
      expect((await w.documents.useDiskVersion('app.py')).isOk, isTrue);
      await _drain();
      final doc = w.doc('app.py');
      expect(doc.conflict, isNull);
      expect(doc.dirty, isFalse);
      expect(doc.savedText, 'print("theirs")\n');
      expect(
        w.container.read(editorHostProvider).textOf(doc.docId),
        'print("theirs")\n',
      );
      expect(w.page.documents[doc.docId]!.text, 'print("theirs")\n');
      expect(await w.journal(), isEmpty);
    });

    test('a deleted file comes back with its changes, or closes', () async {
      final files = MemoryFileService();
      final sessions = MemorySessionStore();
      final first = _World(files: files, sessions: sessions);
      await first.startEditor();
      await first.documents.open('utils.js');
      await _drain();
      first.page.typeText('// keep me\n');
      await _drain();
      final mine = first.container
          .read(editorHostProvider)
          .textOf(first.doc('utils.js').docId);
      await first.documents.persisted;
      first.kill();
      files.remove('utils.js');

      final discard = await _restart(files, sessions);
      expect(discard.doc('utils.js').conflict, DocumentConflict.deleted);
      expect(discard.doc('utils.js').stamp, isNull);
      expect(discard.doc('utils.js').dirty, isTrue);
      await discard.documents.persisted;
      discard.kill();

      final keep = await _restart(files, sessions);
      keep.documents.keepRestoredEdits('utils.js');
      expect((await keep.documents.save('utils.js')).isOk, isTrue);
      expect(files.textOf('utils.js'), mine);
      expect(keep.doc('utils.js').dirty, isFalse);

      files.remove('utils.js');
      keep.page.typeText('more', docId: keep.doc('utils.js').docId);
      await _drain();
      await keep.documents.persisted;
      keep.kill();
      final close = await _restart(files, sessions);
      expect(close.doc('utils.js').conflict, DocumentConflict.deleted);
      expect((await close.documents.useDiskVersion('utils.js')).isOk, isTrue);
      expect(close.state.isOpen('utils.js'), isFalse);
      expect(await close.journal(), isEmpty);
    });

    test('an unreadable file keeps the changes until told', () async {
      final files = MemoryFileService();
      final sessions = MemorySessionStore();
      final first = _World(files: files, sessions: sessions);
      await first.startEditor();
      await first.documents.open('utils.js');
      await _drain();
      first.page.typeText('// keep me\n');
      await _drain();
      final mine = first.container
          .read(editorHostProvider)
          .textOf(first.doc('utils.js').docId);
      await first.documents.persisted;
      first.kill();
      // Another program saved it as UTF-16 meanwhile: no longer readable.
      final utf16 = [0xFF, 0xFE, 0x41, 0x00];
      files.putBytes('utils.js', utf16);

      final ask = await _restart(files, sessions);
      final restored = ask.doc('utils.js');
      expect(restored.conflict, DocumentConflict.unreadable);
      expect(restored.dirty, isTrue);
      expect(restored.stamp, isNull);
      expect(
        ask.container.read(editorHostProvider).textOf(restored.docId),
        mine,
      );
      await ask.documents.persisted;
      ask.kill();

      // Unanswered, it asks again; keeping the changes saves them over it.
      final keep = await _restart(files, sessions);
      expect(keep.doc('utils.js').conflict, DocumentConflict.unreadable);
      keep.documents.keepRestoredEdits('utils.js');
      expect(keep.doc('utils.js').conflict, isNull);
      expect((await keep.documents.save('utils.js')).isOk, isTrue);
      expect(files.textOf('utils.js'), mine);
      expect(keep.doc('utils.js').dirty, isFalse);

      files.putBytes('utils.js', utf16);
      keep.page.typeText('more', docId: keep.doc('utils.js').docId);
      await _drain();
      await keep.documents.persisted;
      keep.kill();
      final close = await _restart(files, sessions);
      expect(close.doc('utils.js').conflict, DocumentConflict.unreadable);
      expect((await close.documents.useDiskVersion('utils.js')).isOk, isTrue);
      expect(close.state.isOpen('utils.js'), isFalse);
      expect(await close.journal(), isEmpty);
    });

    test(
      'a journal that matches the file reopens clean, even untabbed',
      () async {
        final files = MemoryFileService();
        final sessions = MemorySessionStore();
        await sessions.writeSnapshot(
          JournalSnapshot(
            workspaceId: 'demo',
            path: 'main.js',
            text: files.textOf('main.js')!,
            version: 3,
            baseDigest: 'from an older save',
            format: TextFormat.standard,
            language: 'javascript',
          ),
        );
        final w = await _restart(files, sessions, fallback: 'README.md');
        expect(w.state.openPaths, ['main.js'], reason: 'no fallback needed');
        expect(w.doc('main.js').dirty, isFalse);
        expect(await w.journal(), isEmpty);
      },
    );

    test('a damaged journal keeps the text up to the damage', () async {
      final files = MemoryFileService();
      final sessions = MemorySessionStore();
      await sessions.writeSnapshot(
        JournalSnapshot(
          workspaceId: 'demo',
          path: 'README.md',
          text: 'draft',
          version: 1,
          baseDigest: textDigest(files.textOf('README.md')!),
          format: TextFormat.standard,
          language: 'markdown',
        ),
      );
      await sessions.appendChange(
        'demo',
        'README.md',
        const JournalChange(
          baseVersion: 1,
          version: 2,
          lengthBefore: 5,
          lengthAfter: 6,
          changes: [
            5,
            [0, '!'],
          ],
        ),
      );
      await sessions.appendChange(
        'demo',
        'README.md',
        const JournalChange(
          baseVersion: 2,
          version: 3,
          lengthBefore: 99,
          lengthAfter: 100,
          changes: [
            99,
            [0, '?'],
          ],
        ),
      );
      final w = await _restart(files, sessions);
      final doc = w.doc('README.md');
      final host = w.container.read(editorHostProvider);
      expect(host.textOf(doc.docId), 'draft!');
      expect(host.versionOf(doc.docId), 2);
      expect(doc.dirty, isTrue);
      final entry = (await w.journal()).single;
      expect(entry.snapshot.text, 'draft!');
      expect(entry.changes, isEmpty, reason: 'rewritten as one snapshot');
    });

    test('a journal that cannot be written says so, until it can', () async {
      final sessions = FlakySessionStore();
      final w = _World(sessions: sessions);
      await w.startEditor();
      await w.documents.open('main.js');
      await _drain();
      await w.documents.persisted;
      sessions.failing = true;
      w.page.typeText('x');
      await _drain();
      await w.documents.persisted;
      expect(w.state.journalProblem, isNotNull);

      sessions.failing = false;
      w.page.typeText('y');
      await _drain();
      await w.documents.persisted;
      expect(w.state.journalProblem, isNull);
      expect(_replayed((await w.journal()).single), endsWith('xy'));
    });
  });

  group('large files (W7)', () {
    // One character over the policy's threshold.
    final big = 'x' * (plainTextAboveChars + 1);

    test('a large document opens as plain text, and says so', () async {
      final w = _World();
      w.files
        ..putText('big.js', big)
        ..putText('edge.js', 'x' * plainTextAboveChars)
        ..putText('big.txt', big);
      await w.startEditor();
      await w.documents.open('big.js');
      await w.documents.open('edge.js');
      await w.documents.open('big.txt');
      await _drain();
      final doc = w.doc('big.js');
      expect(doc.language, plainTextLanguage);
      expect(doc.largeFile, isTrue);
      expect(doc.largeFileNotice, isTrue);
      expect(w.page.documents[doc.docId]!.language, plainTextLanguage);
      // At the threshold a document is still highlighted.
      expect(w.doc('edge.js').language, 'javascript');
      expect(w.doc('edge.js').largeFile, isFalse);
      // Plain text has nothing to switch off, so nothing to say.
      final notes = w.doc('big.txt');
      expect(notes.language, plainTextLanguage);
      expect(notes.largeFile, isFalse);
      expect(notes.largeFileNotice, isFalse);
    });

    test('highlight anyway turns it on; dismissing keeps it off', () async {
      final w = _World();
      w.files
        ..putText('big.js', big)
        ..putText('big.py', big);
      await w.startEditor();
      await w.documents.open('main.js');
      await w.documents.open('big.js');
      await w.documents.open('big.py');
      await _drain();

      w.documents.dismissLargeFileNotice('big.py');
      final py = w.doc('big.py');
      expect(py.largeFileNotice, isFalse);
      expect(py.largeFile, isTrue);
      expect(py.language, plainTextLanguage);

      final docId = w.doc('big.js').docId;
      w.documents.highlightAnyway('big.js');
      await _drain();
      final js = w.doc('big.js');
      expect(js.language, 'javascript');
      expect(js.largeFile, isFalse);
      expect(js.largeFileNotice, isFalse);
      expect(w.page.documents[docId]!.language, 'javascript');
      // Only what the policy made plain text: the rest is left alone.
      w.documents
        ..highlightAnyway('main.js')
        ..highlightAnyway('missing.js');
      expect(w.doc('main.js').language, 'javascript');
      expect(w.state.openPaths, ['main.js', 'big.js', 'big.py']);
    });

    test('save as keeps it plain, unless it was highlighted', () async {
      final w = _World();
      w.files
        ..putText('big.js', big)
        ..putText('loud.js', big)
        ..putText('big.txt', big);
      await w.startEditor();
      for (final path in const ['big.js', 'loud.js', 'big.txt']) {
        await w.documents.open(path);
      }
      await _drain();
      w.documents.highlightAnyway('loud.js');
      await _drain();

      expect((await w.documents.saveAs('big.js', 'big.ts')).isOk, isTrue);
      expect((await w.documents.saveAs('loud.js', 'loud.ts')).isOk, isTrue);
      expect((await w.documents.saveAs('big.txt', 'from.js')).isOk, isTrue);
      await _drain();
      final plain = w.doc('big.ts');
      expect(plain.language, plainTextLanguage);
      expect(plain.largeFile, isTrue);
      expect(plain.largeFileNotice, isTrue);
      // Its user switched highlighting on: it follows the new name.
      final loud = w.doc('loud.ts');
      expect(loud.language, 'typescript');
      expect(loud.largeFile, isFalse);
      expect(w.page.documents[loud.docId]!.language, 'typescript');
      // Plain text by name until now: the policy meets it under the new one.
      final renamed = w.doc('from.js');
      expect(renamed.language, plainTextLanguage);
      expect(renamed.largeFile, isTrue);
      expect(renamed.largeFileNotice, isTrue);
      expect(w.page.documents[renamed.docId]!.language, plainTextLanguage);
    });

    test('a large document restored from the journal is plain again', () async {
      final files = MemoryFileService()..putText('big.js', big);
      final sessions = MemorySessionStore();
      final first = _World(files: files, sessions: sessions);
      await first.startEditor();
      await first.documents.open('big.js');
      await _drain();
      first.page.typeText('// unsaved\n');
      await _drain();
      await first.documents.persisted;
      first.kill();

      final second = await _restart(files, sessions);
      final doc = second.doc('big.js');
      expect(doc.dirty, isTrue);
      expect(doc.language, plainTextLanguage);
      expect(doc.largeFile, isTrue);
      expect(doc.largeFileNotice, isTrue);
      expect(second.page.documents[doc.docId]!.language, plainTextLanguage);
    });
  });

  group('workbench intents', () {
    test("the page's shortcuts become intents", () async {
      final w = _World();
      await w.startEditor();
      final intents = <WorkbenchIntent>[];
      final subscription = w.container
          .read(workbenchIntentsProvider)
          .stream
          .listen(intents.add);
      addTearDown(subscription.cancel);
      w.page
        ..pressShortcut('saveAs')
        ..pressShortcut('nextTab')
        ..pressShortcut('closeTab');
      await _drain();
      expect(intents, [
        WorkbenchIntent.saveAs,
        WorkbenchIntent.nextEditor,
        WorkbenchIntent.closeEditor,
      ]);
    });

    test('every forwarded shortcut has an intent', () {
      for (final shortcut in appShortcuts) {
        expect(intentForShortcut, contains(shortcut));
      }
    });
  });
}
