/// Workspaces from shared storage (Phase 3 W2, gate G1): switching between
/// the built-in project and a folder keeps each one's tabs and unsaved
/// text; the open folder comes back after a restart; a missing folder or a
/// lost grant is reported, never thrown; saves in a folder never mark a
/// document saved that is not on disk. Over in-memory stores, a fake
/// storage broker and the scripted editor page; plain tests in real time.
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
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/fake_storage_broker.dart';
import '../support/memory_file_service.dart';

const _uri =
    'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2Fcf-gate';
const _folder = FolderLocation(treeUri: _uri, name: 'cf-gate');

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
    expect(stores.shell.load().folder, _folder);
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
    expect(stores.shell.load().folder, isNull);

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
    await stores.shell.save(const ShellState(folder: _folder));
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
}
