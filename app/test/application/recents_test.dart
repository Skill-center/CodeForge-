/// Home's recents (Phase 3 W3, gate G2): every project and folder opened
/// before, most recently opened first, with its kind, place and status;
/// project folders without a record still listed; folders recorded before
/// the recents kept places found again through the app's grants and the
/// shell. Over in-memory stores, in-memory project folders and a fake
/// storage broker; plain tests in real time.
library;

import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/recents_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_storage_broker.dart';
import '../support/memory_project_storage.dart';

const _here =
    'content://com.android.externalstorage.documents/tree/primary%3Ahere';
const _gone =
    'content://com.android.externalstorage.documents/tree/primary%3Agone';
const _lost =
    'content://com.android.externalstorage.documents/tree/primary%3Alost';

final class _Stores {
  final shell = InMemoryShellStateStore();
  final sessions = MemorySessionStore();
  final projects = MemoryProjectStorage();
  final broker = FakeStorageBroker();

  ProviderContainer container() => ProviderContainer.test(
    overrides: [
      shellStateStoreProvider.overrideWithValue(shell),
      sessionStoreProvider.overrideWithValue(sessions),
      projectStorageProvider.overrideWithValue(projects),
      storageBrokerProvider.overrideWithValue(broker),
    ],
  );

  /// Records [workspace] as opened, after the ones before it.
  Future<void> touch(WorkspaceLocation workspace) async {
    await sessions.touchWorkspace(
      workspace,
      displayPath: displayPathOf(workspace),
    );
  }
}

Future<RecentsState> _refresh(ProviderContainer container) async {
  await container.read(recentsProvider.notifier).refresh();
  return container.read(recentsProvider);
}

Map<String, WorkspaceStatus> _statuses(RecentsState state) => {
  for (final entry in state.entries) entry.location.name: entry.status,
};

void main() {
  test(
    'most recently opened first, each with its kind, place and status',
    () async {
      final stores = _Stores();
      stores.projects.add('alpha');
      stores.broker
        ..addTree(_here, 'here')
        ..addTree(_gone, 'gone').missing = true
        ..addTree(_lost, 'lost', grant: false);
      await stores.touch(const DemoProjectLocation());
      await stores.touch(
        const ProjectLocation(id: 'project-a', name: 'alpha', folder: 'alpha'),
      );
      await stores.touch(
        const ProjectLocation(id: 'project-b', name: 'beta', folder: 'beta'),
      );
      await stores.touch(const FolderLocation(treeUri: _here, name: 'here'));
      await stores.touch(const FolderLocation(treeUri: _gone, name: 'gone'));
      await stores.touch(const FolderLocation(treeUri: _lost, name: 'lost'));

      final state = await _refresh(stores.container());
      expect(state.loaded, isTrue);
      expect(
        [for (final e in state.entries) e.location.name],
        ['lost', 'gone', 'here', 'beta', 'alpha', demoProjectName],
      );
      expect(_statuses(state), {
        'lost': WorkspaceStatus.accessLost,
        'gone': WorkspaceStatus.missing,
        'here': WorkspaceStatus.available,
        // Its folder is not among the projects'.
        'beta': WorkspaceStatus.missing,
        'alpha': WorkspaceStatus.available,
        // Written again whenever it opens.
        demoProjectName: WorkspaceStatus.available,
      });
      final here = state.entries[2];
      expect(here.location.kind, WorkspaceKind.folder);
      expect(here.displayPath, 'Internal storage/here');
      expect(state.entries[4].displayPath, 'CodeForge projects/alpha');
      expect(state.projectFolders, unorderedEquals(['beta', 'alpha', 'demo']));
    },
  );

  test('project folders without a record are listed, after the rest', () async {
    final stores = _Stores();
    stores.projects
      ..add('zeta')
      ..add('demo')
      ..add('recorded');
    await stores.touch(
      const ProjectLocation(
        id: 'project-r',
        name: 'recorded',
        folder: 'recorded',
      ),
    );
    final state = await _refresh(stores.container());
    expect(
      [for (final e in state.entries) e.location.id],
      ['project-r', demoWorkspaceId, adoptedProjectId('zeta')],
    );
    expect(state.entries[1].location, const DemoProjectLocation());
    expect(state.entries.last.status, WorkspaceStatus.available);
  });

  test('folders recorded before the recents kept places find them in the '
      "app's grants and the shell, and keep them", () async {
    final stores = _Stores();
    stores.broker
      ..addTree(_here, 'here')
      ..addTree(_gone, 'gone');
    // As schema v1 left them: ids from the URIs, no places.
    await stores.touch(
      FolderLocation(treeUri: '', name: 'here', id: folderWorkspaceId(_here)),
    );
    await stores.touch(
      FolderLocation(treeUri: '', name: 'gone', id: folderWorkspaceId(_gone)),
    );
    await stores.touch(
      FolderLocation(treeUri: '', name: 'lost', id: folderWorkspaceId(_lost)),
    );
    // The shell remembered the open folder (Phase 3 W2's envelope).
    await stores.shell.save(
      const ShellState(
        workspace: FolderLocation(treeUri: _gone, name: 'gone'),
      ),
    );
    stores.broker.granted.remove(_gone);

    final state = await _refresh(stores.container());
    expect(_statuses(state), {
      'here': WorkspaceStatus.available,
      // Its grant is gone, but the shell knew its place.
      'gone': WorkspaceStatus.accessLost,
      // Nothing knows its place: it can only be reconnected.
      'lost': WorkspaceStatus.accessLost,
    });
    final records = {
      for (final r in (await stores.sessions.loadWorkspaces()).orThrow)
        r.name: r,
    };
    expect(records['here']!.location, _here);
    expect(records['here']!.displayPath, 'Internal storage/here');
    expect(records['gone']!.location, _gone);
    expect(records['lost']!.location, isEmpty);
    expect(records['here']!.id, folderWorkspaceId(_here));
  });

  test('the open workspace is listed even without a record', () async {
    final stores = _Stores();
    stores.projects.add('mine');
    const mine = ProjectLocation(id: 'project-m', name: 'mine', folder: 'mine');
    await stores.shell.save(const ShellState(workspace: mine));
    final state = await _refresh(stores.container());
    expect(state.entries.first.location, mine);
    expect(state.entries.first.status, WorkspaceStatus.available);
    expect(state.entries, hasLength(1));
  });

  test('a folder whose check fails is unknown, not an error', () async {
    final stores = _Stores();
    stores.broker.addTree(_here, 'here');
    await stores.touch(const FolderLocation(treeUri: _here, name: 'here'));
    final container = stores.container();
    container.read(recentsProvider);
    stores.broker.failNextCheck = const FileFailure(
      'The storage did not answer.',
      problem: FileProblem.timeout,
    );
    final state = await _refresh(container);
    expect(state.entries.single.status, WorkspaceStatus.unknown);
  });
}
