/// Workspaces (Phase 3 W2, gate G1; W3, gates G2 and G5): switching between
/// projects and folders keeps each one's tabs and unsaved text; the open
/// workspace comes back after a restart; a missing folder or a lost grant
/// is reported, never thrown; saves in a folder never mark a document
/// saved that is not on disk. Projects are created, renamed and deleted,
/// their tabs and unsaved text following a rename and going with a
/// delete; folders leave the recents giving their grant back, and are
/// reconnected keeping their id. Over in-memory stores, a fake storage
/// broker, in-memory project folders and the scripted editor page; plain
/// tests in real time.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/workspace_controller.dart';
import 'package:codeforge/application/workspace_switcher.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/files/demo_workspace.dart';
import 'package:codeforge/services/files/storage_broker.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/fake_storage_broker.dart';
import '../support/memory_file_service.dart';
import '../support/memory_project_storage.dart';

const _uri =
    'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2Fcf-gate';
const _folder = FolderLocation(treeUri: _uri, name: 'cf-gate');

/// Where the folder is after it moved, and two more folders.
const _movedUri =
    'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2Fcf-moved';
const _otherUri =
    'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2Fother';
const _thirdUri =
    'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2Fthird';

/// Lets streams and microtasks run.
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Matcher _fails(FileProblem problem) =>
    isA<FileFailure>().having((f) => f.problem, 'problem', problem);

/// One app over shared stores: a second one is the app after a restart.
final class _App {
  _App(this.stores) {
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        shellStateStoreProvider.overrideWithValue(stores.shell),
        projectFileServiceProvider.overrideWithValue(stores.project),
        projectStorageProvider.overrideWithValue(stores.projects),
        storageBrokerProvider.overrideWithValue(stores.broker),
        sessionStoreProvider.overrideWithValue(stores.sessions),
        folderPickerStartProvider.overrideWithValue('content://start-here'),
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final _Stores stores;
  final List<FakeEditorSurface> pages = [];
  late final ProviderContainer container;

  WorkspaceSwitcher get switcher => container.read(workspaceSwitcherProvider);

  DocumentController get documents =>
      container.read(documentControllerProvider.notifier);

  DocumentsState get state => container.read(documentControllerProvider);

  WorkspaceState get workspace => container.read(workspaceControllerProvider);

  FakeEditorSurface get page => pages.single;

  String? text(String path) =>
      container.read(editorHostProvider).textOf(state.documents[path]!.docId);

  Future<void> startEditor() async {
    await container.read(editorHostProvider).start();
    await _drain();
  }

  /// What the workbench does when it opens.
  Future<void> enterWorkbench() async {
    final opened = await container
        .read(workspaceControllerProvider.notifier)
        .open();
    if (opened case Ok<WorkspaceRef>(:final value)) {
      await documents.restoreTabs(
        fallback: value.id == demoWorkspaceId ? 'main.js' : null,
      );
    }
    await _drain();
  }
}

final class _Stores {
  _Stores() {
    folder = broker.addTree(
      _uri,
      'cf-gate',
      files: {'hello.txt': 'Hello from the gate\n', 'src/main.js': 'run();\n'},
    );
  }

  final shell = InMemoryShellStateStore();
  final sessions = MemorySessionStore();
  final project = MemoryFileService();
  final projects = MemoryProjectStorage();
  final broker = FakeStorageBroker();
  late final FakeFolder folder;
}

void main() {
  test('each workspace keeps its own tabs and unsaved text', () async {
    final stores = _Stores();
    final app = _App(stores);
    await app.startEditor();
    await app.enterWorkbench();
    expect(app.state.openPaths, ['main.js']);
    app.page.typeText('// project edit\n');
    await _drain();

    expect((await app.switcher.open(_folder)).isOk, isTrue);
    await _drain();
    expect(app.state.openPaths, isEmpty);
    expect(app.page.documents, isEmpty);
    expect(stores.shell.load().workspace, _folder);
    await app.enterWorkbench();
    expect(app.workspace.workspace?.displayName, 'cf-gate');
    expect(app.state.openPaths, isEmpty, reason: 'no main.js in a folder');
    await app.documents.open('hello.txt');
    await _drain();
    app.page.typeText('// folder edit\n');
    await _drain();

    expect((await app.switcher.open(const DemoProjectLocation())).isOk, isTrue);
    await app.enterWorkbench();
    expect(app.state.openPaths, ['main.js']);
    expect(app.text('main.js'), endsWith('// project edit\n'));
    expect(app.state.documents['main.js']!.dirty, isTrue);
    expect(stores.shell.load().workspace, const DemoProjectLocation());

    await app.switcher.open(_folder);
    await app.enterWorkbench();
    expect(app.state.openPaths, ['hello.txt']);
    expect(app.text('hello.txt'), 'Hello from the gate\n// folder edit\n');
    // Nothing was saved anywhere: both edits wait in the journal.
    expect(stores.folder.text('hello.txt'), 'Hello from the gate\n');
    final folderJournal = (await stores.sessions.loadJournal(
      _folder.id,
    )).orThrow;
    expect([for (final e in folderJournal) e.path], ['hello.txt']);
    final projectJournal = (await stores.sessions.loadJournal(
      demoWorkspaceId,
    )).orThrow;
    expect([for (final e in projectJournal) e.path], ['main.js']);
  });

  test('a restart reopens the folder with its tabs', () async {
    final stores = _Stores();
    final first = _App(stores);
    await first.startEditor();
    await first.switcher.open(_folder);
    await first.enterWorkbench();
    await first.documents.open('src/main.js');
    await first.documents.checkpoint();
    first.container.dispose();

    final again = _App(stores);
    await again.startEditor();
    expect(again.container.read(currentWorkspaceProvider), _folder);
    await again.enterWorkbench();
    expect(again.workspace.workspace?.id, _folder.id);
    expect(again.state.openPaths, ['src/main.js']);
  });

  test('a missing folder and a lost grant are reported, not thrown', () async {
    final stores = _Stores();
    await stores.shell.save(const ShellState(workspace: _folder));
    stores.folder.missing = true;
    final app = _App(stores);
    await app.startEditor();
    await app.enterWorkbench();
    expect(app.workspace.workspace, isNull);
    expect(app.workspace.failure, _fails(FileProblem.folderMissing));
    expect(app.workspace.failure!.message, contains('cf-gate'));
    expect(app.state.openPaths, isEmpty);

    stores.folder.missing = false;
    stores.broker.granted.clear();
    await app.enterWorkbench();
    expect(app.workspace.failure, _fails(FileProblem.accessLost));

    // Deleted while open: the next listing says so.
    stores.broker.granted.add(_uri);
    await app.enterWorkbench();
    expect(app.workspace.workspace?.displayName, 'cf-gate');
    stores.folder.missing = true;
    await app.container.read(workspaceControllerProvider.notifier).refresh();
    expect(
      app.workspace.listings['']?.failureOrNull,
      _fails(FileProblem.folderMissing),
    );
  });

  test('picking a folder opens it; backing out changes nothing', () async {
    final stores = _Stores();
    final app = _App(stores);
    await app.startEditor();
    stores.broker.pickAnswer = null;
    expect((await app.switcher.pickFolder()).orThrow, isNull);
    expect(
      app.container.read(currentWorkspaceProvider),
      isA<DemoProjectLocation>(),
    );
    stores.broker.pickAnswer = _uri;
    final opened = (await app.switcher.pickFolder()).orThrow;
    expect(opened?.displayName, 'cf-gate');
    expect(app.container.read(currentWorkspaceProvider), _folder);
    expect(stores.broker.pickStarts, [
      'content://start-here',
      'content://start-here',
    ]);
  });

  test('a save in a folder is confirmed before the tab turns clean', () async {
    final stores = _Stores();
    final app = _App(stores);
    await app.startEditor();
    await app.switcher.open(_folder);
    await app.enterWorkbench();
    await app.documents.open('hello.txt');
    await _drain();
    app.page.typeText('more\n');
    await _drain();

    stores.broker.failNextWrite = const FileFailure(
      'The provider failed.',
      problem: FileProblem.io,
    );
    final failed = await app.documents.save('hello.txt');
    expect(failed.failureOrNull, _fails(FileProblem.io));
    expect(app.state.documents['hello.txt']!.dirty, isTrue);

    stores.folder.putText('hello.txt', 'changed by another app\n');
    expect(
      (await app.documents.save('hello.txt')).failureOrNull,
      _fails(FileProblem.changedOnDisk),
    );
    expect(stores.folder.text('hello.txt'), 'changed by another app\n');
    expect(app.state.documents['hello.txt']!.dirty, isTrue);

    expect(
      (await app.documents.save('hello.txt', overwrite: true)).isOk,
      isTrue,
    );
    expect(stores.folder.text('hello.txt'), 'Hello from the gate\nmore\n');
    expect(app.state.documents['hello.txt']!.dirty, isFalse);
  });

  group('projects (Phase 3 W3)', () {
    test('a new project opens, empty or with the demo files, and the '
        'recents record it', () async {
      final stores = _Stores();
      final app = _App(stores);
      await app.startEditor();
      final created = (await app.switcher.createProject('my app')).orThrow;
      expect(created.name, 'my app');
      expect(created.folder, 'my app');
      expect(isWorkspaceId(created.id), isTrue);
      expect(stores.projects.projects['my app']!.paths, isEmpty);

      expect((await app.switcher.open(created)).isOk, isTrue);
      await app.enterWorkbench();
      expect(app.workspace.workspace?.displayName, 'my app');
      expect(app.state.openPaths, isEmpty, reason: 'main.js is the demo’s');
      expect(stores.shell.load().workspace, created);

      final sample = (await app.switcher.createProject(
        'sample',
        fromTemplate: true,
      )).orThrow;
      expect(
        stores.projects.projects['sample']!.paths,
        unorderedEquals(DemoWorkspace.files.keys),
      );
      final records = (await stores.sessions.loadWorkspaces()).orThrow;
      expect([
        for (final r in records) r.id,
      ], containsAll([created.id, sample.id]));
      final record = records.firstWhere((r) => r.id == created.id);
      expect(record.kind, WorkspaceKind.project);
      expect(record.location, 'my app');
      expect(record.displayPath, 'CodeForge projects/my app');
    });

    test('a name that is taken, reserved or not valid is refused', () async {
      final stores = _Stores();
      stores.projects.add('My App');
      final app = _App(stores);
      for (final name in [
        'my app',
        'demo',
        'DEMO',
        'a/b',
        '',
        '.hidden',
        ' padded',
        'x.cf-tmp',
        'x.seeding',
      ]) {
        expect(
          (await app.switcher.createProject(name)).failureOrNull,
          isA<FileFailure>(),
          reason: name,
        );
      }
      expect(stores.projects.projects.keys, ['My App']);
    });

    test('a renamed project keeps its id, so its tabs and unsaved text '
        'follow', () async {
      final stores = _Stores();
      final app = _App(stores);
      await app.startEditor();
      final alpha = (await app.switcher.createProject('alpha')).orThrow;
      stores.projects.projects['alpha']!.putText('a.js', 'a\n');
      await app.switcher.open(alpha);
      await app.enterWorkbench();
      await app.documents.open('a.js');
      await _drain();
      app.page.typeText('// edit\n');
      await _drain();

      final renamed = (await app.switcher.renameProject(alpha, 'beta')).orThrow;
      expect(renamed.id, alpha.id);
      expect(renamed.folder, 'beta');
      expect(stores.projects.projects.keys, contains('beta'));
      expect(stores.projects.projects.keys, isNot(contains('alpha')));
      expect(stores.shell.load().workspace, renamed);
      expect(app.state.openPaths, isEmpty, reason: 'stored and closed');

      await app.enterWorkbench();
      expect(app.workspace.workspace?.displayName, 'beta');
      expect(app.state.openPaths, ['a.js']);
      expect(app.text('a.js'), endsWith('// edit\n'));
      expect(app.state.documents['a.js']!.dirty, isTrue);
      final record = (await stores.sessions.loadWorkspaces()).orThrow
          .firstWhere((r) => r.id == alpha.id);
      expect(record.name, 'beta');
      expect(record.location, 'beta');
      expect(record.displayPath, 'CodeForge projects/beta');
    });

    test('a rename to a taken name changes nothing; the demo project keeps '
        'its name', () async {
      final stores = _Stores();
      final app = _App(stores);
      await app.startEditor();
      final one = (await app.switcher.createProject('one')).orThrow;
      await app.switcher.createProject('two');
      expect(
        (await app.switcher.renameProject(one, 'TWO')).failureOrNull,
        isA<FileFailure>(),
      );
      expect(stores.projects.projects.keys, unorderedEquals(['one', 'two']));
      expect(
        (await app.switcher.renameProject(
          const DemoProjectLocation(),
          'mine',
        )).failureOrNull,
        isA<FileFailure>(),
      );
      // A change of case alone is a rename.
      final cased = (await app.switcher.renameProject(one, 'One')).orThrow;
      expect(cased.folder, 'One');
      expect(stores.projects.projects.keys, unorderedEquals(['One', 'two']));
    });

    test('deleting a project removes its folder and everything kept for it; '
        'the demo project opens in its place', () async {
      final stores = _Stores();
      final app = _App(stores);
      await app.startEditor();
      final doomed = (await app.switcher.createProject('doomed')).orThrow;
      stores.projects.projects['doomed']!.putText('a.js', 'a\n');
      await app.switcher.open(doomed);
      await app.enterWorkbench();
      await app.documents.open('a.js');
      await _drain();
      app.page.typeText('x');
      await _drain();

      final contents = await app.switcher.projectContents(doomed);
      expect(contents.files, 1);
      expect(contents.unsaved, 1);
      expect((await app.switcher.deleteProject(doomed)).isOk, isTrue);
      expect(stores.projects.projects.keys, isNot(contains('doomed')));
      expect(stores.shell.load().workspace, const DemoProjectLocation());
      expect(app.state.openPaths, isEmpty);
      expect((await stores.sessions.loadJournal(doomed.id)).orThrow, isEmpty);
      expect((await stores.sessions.loadTabs(doomed.id)).orThrow, isEmpty);
      expect([
        for (final r in (await stores.sessions.loadWorkspaces()).orThrow) r.id,
      ], isNot(contains(doomed.id)));

      await app.enterWorkbench();
      expect(app.workspace.workspace?.id, demoWorkspaceId);
      expect(app.state.openPaths, ['main.js']);
    });

    test('a project whose folder is gone is reported, not thrown', () async {
      final stores = _Stores();
      final app = _App(stores);
      await app.startEditor();
      final gone = (await app.switcher.createProject('gone')).orThrow;
      stores.projects.projects.remove('gone');
      final opened = await app.switcher.open(gone);
      expect(opened.failureOrNull, _fails(FileProblem.folderMissing));
      expect(opened.failureOrNull!.message, contains('"gone"'));
    });
  });

  group('folders in the recents (Phase 3 W3)', () {
    test('removing a folder gives its grant back and forgets it; its files '
        'stay', () async {
      final stores = _Stores();
      final app = _App(stores);
      await app.startEditor();
      await app.switcher.open(_folder);
      await app.enterWorkbench();
      await app.documents.open('hello.txt');
      await _drain();
      app.page.typeText('// edit\n');
      await _drain();
      expect(await app.switcher.unsavedCount(_folder), 1);

      expect((await app.switcher.removeFolder(_folder)).isOk, isTrue);
      expect(stores.broker.released, [_uri]);
      expect(stores.shell.load().workspace, const DemoProjectLocation());
      expect(app.state.openPaths, isEmpty);
      expect([
        for (final r in (await stores.sessions.loadWorkspaces()).orThrow) r.id,
      ], isNot(contains(_folder.id)));
      expect((await stores.sessions.loadJournal(_folder.id)).orThrow, isEmpty);
      expect(stores.folder.text('hello.txt'), 'Hello from the gate\n');
    });

    test('a folder reconnected at its new place keeps its id, tabs and '
        'unsaved text, and gives the old grant back', () async {
      final stores = _Stores();
      final app = _App(stores);
      await app.startEditor();
      await app.switcher.open(_folder);
      await app.enterWorkbench();
      await app.documents.open('hello.txt');
      await _drain();
      app.page.typeText('// edit\n');
      await _drain();

      // The folder moved: gone from its place, there under another name.
      stores.folder.missing = true;
      stores.broker.addTree(
        _movedUri,
        'cf-moved',
        files: {'hello.txt': 'Hello from the gate\n'},
        grant: false,
      );
      stores.broker.pickAnswer = _movedUri;
      final picked = (await app.switcher.pickForReconnect(_folder)).orThrow!;
      expect(stores.broker.pickStarts.last, folderPickerStart(_uri));
      expect(app.switcher.isSameFolder(_folder, picked), isFalse);

      expect((await app.switcher.reconnect(_folder, picked)).isOk, isTrue);
      final moved = stores.shell.load().workspace! as FolderLocation;
      expect(moved.id, _folder.id);
      expect(moved.treeUri, _movedUri);
      expect(moved.name, 'cf-moved');
      expect(stores.broker.released, [_uri]);
      await app.enterWorkbench();
      expect(app.state.openPaths, ['hello.txt']);
      expect(app.text('hello.txt'), endsWith('// edit\n'));
      final record = (await stores.sessions.loadWorkspaces()).orThrow
          .firstWhere((r) => r.id == _folder.id);
      expect(record.location, _movedUri);
      expect(record.displayPath, 'Internal storage/Documents/cf-moved');

      // Picked again later, the folder is the same entry.
      stores.broker.pickAnswer = _movedUri;
      final again = (await app.switcher.pickFolder()).orThrow;
      expect(again?.id, _folder.id);
    });

    test('the same folder picked again reconnects as it is', () async {
      final stores = _Stores();
      final app = _App(stores);
      await app.startEditor();
      await app.switcher.open(_folder);
      stores.broker.granted.clear();
      stores.broker.pickAnswer = _uri;
      final picked = (await app.switcher.pickForReconnect(_folder)).orThrow!;
      expect(app.switcher.isSameFolder(_folder, picked), isTrue);
      expect((await app.switcher.reconnect(_folder, picked)).isOk, isTrue);
      expect(stores.broker.released, isEmpty);
      expect(stores.shell.load().workspace, _folder);
    });

    test('a folder already in the recents is not taken over; a folder '
        'picked and turned down gives its grant back', () async {
      final stores = _Stores();
      stores.broker
        ..addTree(_otherUri, 'other', files: {'o.txt': 'o\n'})
        ..addTree(_thirdUri, 'third', files: {'t.txt': 't\n'});
      final app = _App(stores);
      await app.startEditor();
      await app.switcher.open(_folder);
      await app.switcher.open(
        const FolderLocation(treeUri: _otherUri, name: 'other'),
      );
      final other = (await stores.broker.checkFolder(_otherUri)).orThrow;
      expect(
        (await app.switcher.reconnect(_folder, other)).failureOrNull,
        _fails(FileProblem.exists),
      );
      await app.switcher.dropPicked(other);
      expect(stores.broker.released, isEmpty, reason: 'in the recents');
      final third = (await stores.broker.checkFolder(_thirdUri)).orThrow;
      await app.switcher.dropPicked(third);
      expect(stores.broker.released, [_thirdUri]);
    });

    test(
      'a folder recorded without its place can only be reconnected',
      () async {
        final stores = _Stores();
        final app = _App(stores);
        final unplaced = FolderLocation(
          treeUri: '',
          name: 'cf-gate',
          id: folderWorkspaceId(_uri),
        );
        final opened = await app.switcher.open(unplaced);
        expect(opened.failureOrNull, _fails(FileProblem.accessLost));
        expect(
          app.container.read(currentWorkspaceProvider).id,
          demoWorkspaceId,
        );
        // Its own folder, picked to reconnect it, is recognised by its id.
        const info = FolderInfo(
          treeUri: _uri,
          name: 'cf-gate',
          status: FolderStatus.available,
        );
        expect(app.switcher.isSameFolder(unplaced, info), isTrue);
      },
    );
  });
}
