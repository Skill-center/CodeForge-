/// DocumentController (Phase 2 W4): open documents, tabs, dirty state,
/// save, Save As, New File and tab restore, over an in-memory workspace and
/// the scripted editor page. Plain tests in real time.
library;

import 'dart:convert';

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/application/workbench_intents.dart';
import 'package:codeforge/application/workspace_controller.dart';
import 'package:codeforge/core/editor/protocol.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/memory_file_service.dart';

/// One app's worth of providers over [files] and [shellStore].
final class _World {
  _World({MemoryFileService? files, InMemoryShellStateStore? shellStore})
    : files = files ?? MemoryFileService(),
      shellStore = shellStore ?? InMemoryShellStateStore() {
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        shellStateStoreProvider.overrideWithValue(this.shellStore),
        fileServiceProvider.overrideWithValue(this.files),
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final MemoryFileService files;
  final InMemoryShellStateStore shellStore;
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
}

/// Lets streams and microtasks run.
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
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
      expect(w.container.read(shellControllerProvider).openTabs, [
        'src/hello.py',
      ]);
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
      final store = InMemoryShellStateStore();
      final first = _World(files: files, shellStore: store);
      await first.documents.open('main.js');
      await first.documents.open('app.py');
      await first.documents.open('README.md');
      first.documents.activate('app.py');
      await first.container.read(shellControllerProvider.notifier).flush();
      expect(store.load().openTabs, ['main.js', 'app.py', 'README.md']);
      expect(store.load().activeTab, 'app.py');

      final second = _World(files: files, shellStore: store);
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

      final fresh = _World();
      await fresh.documents.restoreTabs(fallback: 'main.js');
      expect(fresh.state.openPaths, ['main.js']);
      // Once per run: closing everything and coming back opens nothing.
      fresh.documents.close('main.js');
      await fresh.documents.restoreTabs(fallback: 'main.js');
      expect(fresh.state.openPaths, isEmpty);
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
