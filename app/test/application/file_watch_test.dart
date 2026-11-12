/// Changes made outside the app (Phase 3 W5, gate G4): the file watcher
/// (FileWatchController) and what DocumentController.checkDisk does with
/// what it finds, over an in-memory workspace whose changes "made by
/// another program" notify their folder, and the scripted editor page.
/// Plain tests in real time, with the watcher's pauses shortened.
library;

import 'package:codeforge/application/documents/disk_notices.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/explorer_view_controller.dart';
import 'package:codeforge/application/file_index.dart';
import 'package:codeforge/application/file_watch_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/workspace_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/files/saf_file_service.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/fake_storage_broker.dart';
import '../support/memory_file_service.dart';

/// Short pauses, and no periodic re-check unless a test asks for one.
const FileWatchSettings _fast = FileWatchSettings(
  batch: Duration(milliseconds: 20),
  recheckEvery: Duration(hours: 1),
);

/// One app's worth of providers over [files] (or over [service], a folder
/// from shared storage), with the file watcher running as the workbench
/// runs it.
final class _World {
  _World({
    MemoryFileService? files,
    this.service,
    FileWatchSettings settings = _fast,
  }) : files = files ?? MemoryFileService() {
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        shellStateStoreProvider.overrideWithValue(InMemoryShellStateStore()),
        fileServiceProvider.overrideWithValue(service ?? this.files),
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        fileWatchSettingsProvider.overrideWithValue(settings),
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final MemoryFileService files;
  final FileService? service;
  final List<FakeEditorSurface> pages = [];
  late final ProviderContainer container;

  /// Every notice shown, in order.
  final List<String> notices = [];

  DocumentController get documents =>
      container.read(documentControllerProvider.notifier);

  DocumentsState get state => container.read(documentControllerProvider);

  EditorHost get host => container.read(editorHostProvider);

  FakeEditorSurface get page => pages.single;

  FileWatchController get watcher =>
      container.read(fileWatchProvider.notifier);

  OpenDocument doc(String path) => state.documents[path]!;

  /// What the page shows for [path].
  String? pageText(String path) => page.documents[doc(path).docId]?.text;

  /// The editor page, the workspace's root listing and the watcher.
  Future<void> start() async {
    await host.start();
    await container.read(workspaceControllerProvider.notifier).open();
    container
      ..listen(fileWatchProvider, (_, _) {})
      ..listen(diskNoticesProvider, (_, notice) {
        if (notice != null) {
          notices.add(notice.message);
        }
      });
    await _drain();
  }

  /// Opens [path] and waits until the page has it.
  Future<void> open(String path) async {
    expect((await documents.open(path)).isOk, isTrue, reason: path);
    await _drain();
  }
}

/// Lets streams and microtasks run.
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Waits, in real time, until [condition] holds.
Future<void> _until(
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('Timed out waiting for $what.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await _drain();
}

/// Waits long enough for a batch that is not coming to have come.
Future<void> _quiet() async {
  await Future<void>.delayed(const Duration(milliseconds: 120));
  await _drain();
}

Matcher _fails(FileProblem problem) =>
    isA<FileFailure>().having((f) => f.problem, 'problem', problem);

void main() {
  group('what is watched', () {
    test('the root, open documents\' folders, then expanded folders', () {
      expect(
        foldersToWatch(
          openPaths: ['a/b/c.txt', 'main.js', 'x/y.txt'],
          activePath: 'x/y.txt',
          expanded: {'', 'src', 'src/lib', 'docs', 'hidden/deep'},
          maxFolders: 64,
        ),
        ['', 'x', 'a/b', 'docs', 'src', 'src/lib'],
        reason: 'hidden/deep shows only when hidden is expanded too',
      );
    });

    test('never more than the limit, the most wanted first', () {
      final expanded = {for (var i = 0; i < 100; i++) 'f$i'};
      final folders = foldersToWatch(
        openPaths: ['open/doc.txt'],
        activePath: 'open/doc.txt',
        expanded: expanded,
        maxFolders: 64,
      );
      expect(folders, hasLength(64));
      expect(folders.take(2), ['', 'open']);
    });

    test('follows the tabs and the expanded folders', () async {
      final w = _World();
      await w.start();
      expect(w.files.watched, {''});
      await w.open('src/greeting.dart');
      await _until(
        () => w.files.watched.contains('src'),
        what: 'src to be watched',
      );
      w.documents.close('src/greeting.dart');
      await _until(
        () => !w.files.watched.contains('src'),
        what: 'src to be left',
      );
      w.container.read(explorerViewProvider.notifier).toggle('src');
      await _until(
        () => w.files.watched.contains('src'),
        what: 'the expanded folder to be watched',
      );
      expect(w.container.read(fileWatchProvider), ['', 'src']);
    });
  });

  group('a document without unsaved changes', () {
    test('shows the new text exactly, with a notice', () async {
      final w = _World();
      await w.start();
      await w.open('main.js');
      w.files.putText('main.js', 'changed outside\n');
      await _until(
        () => w.pageText('main.js') == 'changed outside\n',
        what: 'the reload',
      );
      final doc = w.doc('main.js');
      expect(doc.dirty, isFalse);
      expect(doc.conflict, isNull);
      expect(doc.savedText, 'changed outside\n');
      expect(doc.stamp, (await w.files.stat('main.js')).orThrow);
      expect(w.host.textOf(doc.docId), 'changed outside\n');
      expect(w.page.replaces, 1);
      expect(w.notices, ['main.js changed on disk and was reloaded.']);
      // Saved again later: the reloaded stamp is the one expected.
      w.page.typeText('// more\n');
      await _drain();
      expect((await w.documents.save('main.js')).isOk, isTrue);
      expect(w.files.textOf('main.js'), 'changed outside\n// more\n');
    });

    test('a file touched without a new text only takes the new stamp', () async {
      final w = _World();
      await w.start();
      await w.open('utils.js');
      final before = w.doc('utils.js').stamp;
      w.files.putText('utils.js', w.files.textOf('utils.js')!);
      await _until(
        () => w.doc('utils.js').stamp != before,
        what: 'the new stamp',
      );
      expect(w.page.replaces, 0);
      expect(w.notices, isEmpty);
      expect(w.doc('utils.js').dirty, isFalse);
    });

    test('typing that races the reload wins: the page refuses it', () async {
      final w = _World();
      await w.start();
      await w.open('main.js');
      final original = w.pageText('main.js')!;
      w.page.hold = true;
      w.files.putText('main.js', 'theirs\n');
      await _until(
        () => w.page.receivedTypes.contains('doc.replace'),
        what: 'the reload to reach the page',
      );
      w.page.typeText('mine');
      w.page.release();
      await _until(
        () => w.doc('main.js').conflict != null,
        what: 'the conflict',
      );
      expect(w.page.replaces, 0);
      expect(w.pageText('main.js'), '${original}mine');
      expect(w.host.textOf(w.doc('main.js').docId), '${original}mine');
      expect(w.doc('main.js').conflict, DocumentConflict.changedWhileOpen);
      expect(w.doc('main.js').dirty, isTrue);
      expect(w.doc('main.js').savedText, 'theirs\n');
    });

    test('a file that is no longer text leaves the document alone', () async {
      final w = _World();
      await w.start();
      await w.open('utils.js');
      final text = w.pageText('utils.js');
      w.files.putBytes('utils.js', [0x66, 0x00, 0xff, 0xfe]);
      await _quiet();
      await w.documents.checkDisk();
      expect(w.pageText('utils.js'), text);
      expect(w.doc('utils.js').conflict, isNull);
      expect(w.doc('utils.js').dirty, isFalse);
      expect(w.page.replaces, 0);
      expect(w.notices, isEmpty);
    });
  });

  group('a document with unsaved changes', () {
    test('keeps them, and the user chooses', () async {
      final w = _World();
      await w.start();
      await w.open('main.js');
      w.page.typeText('// mine\n');
      await _drain();
      final mine = w.pageText('main.js')!;
      w.files.putText('main.js', 'theirs\n');
      await _until(
        () => w.doc('main.js').conflict != null,
        what: 'the conflict',
      );
      final doc = w.doc('main.js');
      expect(doc.conflict, DocumentConflict.changedWhileOpen);
      expect(doc.conflict!.restored, isFalse);
      expect(doc.dirty, isTrue);
      expect(doc.savedText, 'theirs\n');
      expect(w.pageText('main.js'), mine);
      expect(w.page.replaces, 0);
      expect(w.files.textOf('main.js'), 'theirs\n');
      expect(w.notices.single, contains('Your unsaved changes are kept'));
      expect(w.state.firstConflict, isNull, reason: 'not a restored one');

      // A save asks first; overwriting writes the user's text.
      expect(
        (await w.documents.save('main.js')).failureOrNull,
        _fails(FileProblem.changedOnDisk),
      );
      expect(w.files.textOf('main.js'), 'theirs\n');
      expect((await w.documents.save('main.js', overwrite: true)).isOk, isTrue);
      expect(w.files.textOf('main.js'), mine);
      expect(w.doc('main.js').conflict, isNull);
      expect(w.doc('main.js').dirty, isFalse);
    });

    test('keep mine leaves the text; use the file takes the file', () async {
      final w = _World();
      await w.start();
      await w.open('main.js');
      await w.open('utils.js');
      w.page.typeText('// a\n', docId: w.doc('main.js').docId);
      w.page.typeText('// b\n', docId: w.doc('utils.js').docId);
      await _drain();
      final mine = w.pageText('main.js');
      w.files
        ..putText('main.js', 'theirs a\n')
        ..putText('utils.js', 'theirs b\n');
      await _until(
        () =>
            w.doc('main.js').conflict != null &&
            w.doc('utils.js').conflict != null,
        what: 'both conflicts',
      );

      w.documents.keepRestoredEdits('main.js');
      expect(w.doc('main.js').conflict, isNull);
      expect(w.doc('main.js').dirty, isTrue);
      expect(w.pageText('main.js'), mine);
      // The file's stamp is known: the save writes over it without asking.
      expect((await w.documents.save('main.js')).isOk, isTrue);
      expect(w.files.textOf('main.js'), mine);

      expect((await w.documents.useDiskVersion('utils.js')).isOk, isTrue);
      await _drain();
      expect(w.pageText('utils.js'), 'theirs b\n');
      expect(w.doc('utils.js').conflict, isNull);
      expect(w.doc('utils.js').dirty, isFalse);
    });

    test('changes that match the file make the document clean', () async {
      final w = _World();
      await w.start();
      await w.open('utils.js');
      w.page.typeText('// same\n');
      await _drain();
      final text = w.pageText('utils.js')!;
      w.files.putText('utils.js', text);
      await _until(
        () => !w.doc('utils.js').dirty,
        what: 'the document to turn clean',
      );
      expect(w.doc('utils.js').conflict, isNull);
      expect(w.doc('utils.js').savedText, text);
      expect(w.notices, isEmpty);
    });
  });

  group('a deleted file', () {
    test('closes a clean tab and keeps one with unsaved changes', () async {
      final w = _World();
      await w.start();
      await w.open('utils.js');
      await w.open('app.py');
      w.page.typeText('# unsaved\n', docId: w.doc('app.py').docId);
      await _drain();
      w.files
        ..remove('utils.js')
        ..remove('app.py');
      await _until(
        () =>
            !w.state.isOpen('utils.js') &&
            (w.state.documents['app.py']?.deletedOnDisk ?? false),
        what: 'the tabs to follow the deletes',
      );
      expect(w.doc('app.py').dirty, isTrue);
      expect(w.notices, hasLength(2));
      expect(
        w.notices,
        contains('utils.js was deleted on disk, so its tab closed.'),
      );
      expect(
        w.notices,
        contains(startsWith('app.py was deleted on disk. Your text is still')),
      );
      // Save writes it again.
      expect((await w.documents.save('app.py')).isOk, isTrue);
      expect(w.files.textOf('app.py'), contains('# unsaved'));
    });
  });

  group('the app\'s own writes', () {
    test('a save causes no reload, no notice and no conflict', () async {
      final files = MemoryFileService()..notifyOwnWrites = true;
      final w = _World(files: files);
      await w.start();
      await w.open('main.js');
      w.page.typeText('// saved\n');
      await _drain();
      final text = w.pageText('main.js')!;
      expect((await w.documents.save('main.js')).isOk, isTrue);
      await _quiet();
      await w.documents.checkDisk();
      expect(w.page.replaces, 0);
      expect(w.notices, isEmpty);
      expect(w.doc('main.js').conflict, isNull);
      expect(w.doc('main.js').dirty, isFalse);
      expect(w.pageText('main.js'), text);
      expect(
        w.files.listed.where((p) => p.isEmpty),
        hasLength(2),
        reason: 'the save listed the root once more, and that is all',
      );
    });
  });

  group('the explorer and Go to File', () {
    test('new and deleted files show, and the index follows', () async {
      final w = _World();
      await w.start();
      final index = w.container.read(fileIndexProvider.notifier);
      await index.rebuild();
      List<String> indexed() =>
          [for (final f in w.container.read(fileIndexProvider).files) f.path];
      List<String> rootNames() => [
        for (final e in w.container
            .read(workspaceControllerProvider)
            .listings['']!
            .valueOrNull!)
          e.name,
      ];

      w.files.putText('fresh.txt', 'new\n');
      await _until(() => rootNames().contains('fresh.txt'), what: 'the row');
      await index.settled;
      expect(indexed(), contains('fresh.txt'));

      w.files.putText('made/deep/a.js', '1\n');
      await _until(() => rootNames().contains('made'), what: 'the folder');
      await index.settled;
      expect(indexed(), contains('made/deep/a.js'));

      w.files.remove('fresh.txt');
      await _until(() => !rootNames().contains('fresh.txt'), what: 'no row');
      await index.settled;
      expect(indexed(), isNot(contains('fresh.txt')));
      expect(indexed(), contains('src/notes.txt'), reason: 'others stay');
    });

    test('a burst lists each folder once', () async {
      final w = _World(
        settings: const FileWatchSettings(
          batch: Duration(milliseconds: 80),
          recheckEvery: Duration(hours: 1),
        ),
      );
      await w.start();
      final before = w.files.listed.where((p) => p.isEmpty).length;
      for (var i = 0; i < 25; i++) {
        w.files.putText('burst$i.txt', '$i\n');
      }
      await _until(
        () => w.files.listed.where((p) => p.isEmpty).length > before,
        what: 'the root to be listed again',
      );
      await _quiet();
      expect(w.files.listed.where((p) => p.isEmpty).length, before + 1);
    });

    test('an expanded folder deleted outside leaves the tree', () async {
      final w = _World();
      await w.start();
      final view = w.container.read(explorerViewProvider.notifier);
      final workspace = w.container.read(workspaceControllerProvider.notifier);
      view.toggle('src');
      await workspace.load('src');
      await _until(() => w.files.watched.contains('src'), what: 'the watch');
      w.files
        ..remove('src/greeting.dart')
        ..remove('src/notes.txt');
      await _until(
        () => !w.container.read(workspaceControllerProvider).listings
            .containsKey('src'),
        what: 'the listing to go',
      );
      expect(w.container.read(explorerViewProvider).expanded, {''});
    });
  });

  group('re-checked without notices', () {
    test('every few seconds in the foreground', () async {
      final files = MemoryFileService()..failWatch = const FileFailure(
        'This storage sends no notices.',
        problem: FileProblem.unsupported,
      );
      final w = _World(
        files: files,
        settings: const FileWatchSettings(
          batch: Duration(milliseconds: 20),
          recheckEvery: Duration(milliseconds: 60),
        ),
      );
      await w.start();
      await w.open('main.js');
      w.files.putText('main.js', 'polled\n');
      await _until(
        () => w.pageText('main.js') == 'polled\n',
        what: 'the periodic check',
      );
    });

    test('when a tab is activated', () async {
      final files = MemoryFileService()..failWatch = const FileFailure(
        'This storage sends no notices.',
        problem: FileProblem.unsupported,
      );
      final w = _World(files: files);
      await w.start();
      await w.open('main.js');
      await w.open('utils.js');
      w.files.putText('main.js', 'seen on activation\n');
      await _quiet();
      expect(w.pageText('main.js'), isNot('seen on activation\n'));
      w.documents.activate('main.js');
      await _until(
        () => w.pageText('main.js') == 'seen on activation\n',
        what: 'the activation check',
      );
    });

    test('in the background nothing runs, and coming back catches up', () async {
      final w = _World();
      await w.start();
      await w.open('main.js');
      w.watcher.paused();
      w.files
        ..putText('main.js', 'changed while away\n')
        ..putText('away.txt', 'new\n');
      await _quiet();
      expect(w.pageText('main.js'), isNot('changed while away\n'));
      await w.watcher.resumed();
      await _until(
        () => w.pageText('main.js') == 'changed while away\n',
        what: 'the resume check',
      );
      final root = w.container.read(workspaceControllerProvider).listings['']!;
      expect(
        root.valueOrNull!.map((e) => e.name),
        contains('away.txt'),
      );
    });
  });

  group('a folder from shared storage', () {
    const uri =
        'content://com.android.externalstorage.documents/tree/primary%3Awatch';

    test('its provider\'s notices reload a clean document', () async {
      final broker = FakeStorageBroker();
      final folder = broker.addTree(uri, 'watch', files: {'a.txt': 'one\n'});
      final w = _World(
        service: SafFileService(
          broker: broker,
          folder: const FolderLocation(treeUri: uri, name: 'watch'),
        ),
      );
      await w.start();
      await w.open('a.txt');
      expect(broker.isWatched(uri, ''), isTrue);
      folder.putText('a.txt', 'two\n');
      broker.notifyChanged(uri, '');
      await _until(() => w.pageText('a.txt') == 'two\n', what: 'the reload');
      expect(w.doc('a.txt').dirty, isFalse);
      expect(w.notices, ['a.txt changed on disk and was reloaded.']);
    });
  });
}
