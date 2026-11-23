/// The open project's repository (Phase 7 W2, gate G2): the controller over
/// a scripted repository reads the status once the runtime is ready, only
/// in a project; refreshes after its operations, after a save, on changes
/// in `.git` and when the app comes back, debounced, one status at a time
/// with the newest winning; queues its operations, which the host would
/// refuse as busy; and says what the branch chip says.
library;

import 'dart:async';

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/git/git_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/fake_runtime_service.dart';
import '../support/fake_storage_broker.dart';
import '../support/memory_file_service.dart';
import '../support/scripted_git_service.dart';

const Duration _debounce = Duration(milliseconds: 20);

Future<void> _drain() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Past the debounce, and what it started.
Future<void> _settle() async {
  await Future<void>.delayed(_debounce * 3);
  await _drain();
}

final class _World {
  _World({
    bool runtimeReady = true,
    WorkspaceLocation? location,
    ScriptedGitService? git,
  }) : git = git ?? ScriptedGitService(),
       runtime = FakeRuntimeService(
         state: runtimeReady ? RuntimeState.ready : RuntimeState.installed,
       ) {
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        storageBrokerProvider.overrideWithValue(FakeStorageBroker()),
        shellStateStoreProvider.overrideWithValue(InMemoryShellStateStore()),
        fileServiceProvider.overrideWithValue(files),
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        runtimeServiceProvider.overrideWithValue(runtime),
        gitServiceProvider.overrideWithValue(this.git),
        gitSettingsProvider.overrideWithValue(
          const GitSettings(debounce: _debounce),
        ),
        if (location != null)
          currentWorkspaceProvider.overrideWithValue(location),
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final MemoryFileService files = MemoryFileService();
  final ScriptedGitService git;
  final FakeRuntimeService runtime;
  final List<FakeEditorSurface> pages = [];
  late final ProviderContainer container;

  GitController get controller =>
      container.read(gitControllerProvider.notifier);

  GitRepoState get state => container.read(gitControllerProvider);

  /// The status strip's watch, the editor page and the runtime's status.
  Future<void> start() async {
    container.listen(gitControllerProvider, (previous, next) {});
    await container.read(editorHostProvider).start();
    await container.read(runtimeControllerProvider.notifier).refresh();
    await _drain();
  }
}

GitStatus _changed(String branch, List<String> untracked) => GitStatus(
  branch: GitBranchState(head: branch, oid: 'a' * 40),
  files: [
    for (final path in untracked)
      GitFileStatus(path: path, kind: GitEntryKind.untracked),
  ],
);

void main() {
  test("a project's status is read once the runtime is ready", () async {
    final world = _World(git: ScriptedGitService(status: _changed('dev', ['a'])));
    await world.start();
    expect(world.git.statusCalls, ['demo']);
    expect(world.state.kind, GitRepoKind.repository);
    expect(world.state.project, 'demo');
    expect(world.state.status!.branch.head, 'dev');
    expect(world.state.refreshing, isFalse);
  });

  test('nothing runs before the runtime is ready, nor without a host, nor '
      'in a folder from shared storage', () async {
    final waiting = _World(runtimeReady: false);
    await waiting.start();
    expect(waiting.state.kind, GitRepoKind.waiting);
    expect(waiting.git.statusCalls, isEmpty);

    final noHost = _World(git: ScriptedGitService(available: false));
    await noHost.start();
    expect(noHost.state.kind, GitRepoKind.unavailable);
    expect(noHost.git.statusCalls, isEmpty);
    expect(await noHost.controller.stageAll(), isA<Err<void>>());
    expect(noHost.git.calls, isEmpty);

    final folder = _World(
      location: const FolderLocation(
        treeUri: 'content://tree/primary%3Acode',
        name: 'code',
      ),
    );
    await folder.start();
    expect(folder.state.kind, GitRepoKind.folder);
    expect(folder.git.statusCalls, isEmpty);
    folder.controller.changed();
    await _settle();
    expect(folder.git.statusCalls, isEmpty);
  });

  test('a project that is not a repository says so; one that becomes one '
      'shows', () async {
    final git = ScriptedGitService()
      ..statusResult = const Err(
        GitFailure('Not a repository', problem: GitProblem.notARepository),
      );
    final world = _World(git: git);
    await world.start();
    expect(world.state.kind, GitRepoKind.notARepository);
    git.onOperation = (_) => git.statusResult = const Ok(cleanMain);
    expect((await world.controller.init()).isOk, isTrue);
    expect(git.calls, ['init main']);
    expect(world.state.kind, GitRepoKind.repository);
    expect(world.state.status!.branch.head, 'main');
  });

  test('changes gather: many become one status after the debounce', () async {
    final world = _World();
    await world.start();
    world.git.statusCalls.clear();
    for (var i = 0; i < 5; i++) {
      world.controller.changed();
    }
    expect(world.git.statusCalls, isEmpty);
    await _settle();
    expect(world.git.statusCalls, ['demo']);
  });

  test('one status at a time, and a change during it runs one more after',
      () async {
    final world = _World();
    await world.start();
    world.git.statusCalls.clear();
    final hold = world.git.holdStatus = Completer<void>();
    final first = world.controller.refresh();
    await _drain();
    expect(world.state.refreshing, isTrue);
    // Asked for while the first runs: they wait, and become one.
    final second = world.controller.refresh();
    final third = world.controller.refresh();
    await _drain();
    expect(world.git.statusCalls, hasLength(1));
    world.git.statusResult = Ok(_changed('main', ['new.txt']));
    world.git.holdStatus = null;
    hold.complete();
    await Future.wait([first, second, third]);
    await _drain();
    expect(world.git.statusCalls, hasLength(2));
    expect(world.git.mostStatusesAtOnce, 1);
    // The newest status is the one that stays.
    expect(world.state.status!.files.single.path, 'new.txt');
    expect(world.state.refreshing, isFalse);
  });

  test('operations queue, each refreshing before it answers', () async {
    final world = _World();
    await world.start();
    world.git.statusCalls.clear();
    final hold = world.git.holdOperations = Completer<void>();
    final staged = world.controller.stage(['a.txt']);
    final committed = world.controller.commit('First');
    await _drain();
    expect(world.state.changing, isTrue);
    expect(world.git.calls, ['stage a.txt']);
    world.git.holdOperations = null;
    hold.complete();
    expect((await staged).isOk, isTrue);
    expect((await committed).isOk, isTrue);
    expect(world.git.calls, ['stage a.txt', 'commit First']);
    expect(world.git.mostOperationsAtOnce, 1);
    expect(world.git.statusCalls, hasLength(2));
    expect(world.state.changing, isFalse);
  });

  test("an operation's failure is its answer, and the status still "
      'refreshes', () async {
    final world = _World();
    await world.start();
    world.git
      ..statusCalls.clear()
      ..operationResult = const Err(
        GitFailure('Nothing', problem: GitProblem.nothingToCommit),
      );
    final result = await world.controller.commit('x');
    expect(
      (result.failureOrNull! as GitFailure).problem,
      GitProblem.nothingToCommit,
    );
    expect(world.git.statusCalls, ['demo']);
  });

  test('a save refreshes the status; typing does not', () async {
    final world = _World();
    await world.start();
    await world.container.read(documentControllerProvider.notifier).open(
      'main.js',
    );
    await _settle();
    world.git.statusCalls.clear();
    world.pages.single.typeText('// more\n');
    await _settle();
    expect(world.git.statusCalls, isEmpty);
    final saved = await world.container
        .read(documentControllerProvider.notifier)
        .save('main.js');
    expect(saved.isOk, isTrue);
    await _settle();
    expect(world.git.statusCalls, ['demo']);
  });

  test("a change in the project's .git folder refreshes the status: the "
      "terminal's git shows", () async {
    final world = _World();
    world.files.putFolder('.git');
    await world.start();
    world.git.statusCalls.clear();
    world.files.putText('.git/index', 'changed');
    await _settle();
    expect(world.git.statusCalls, ['demo']);
  });

  test('in the background nothing runs; coming back refreshes', () async {
    final world = _World();
    await world.start();
    world.git.statusCalls.clear();
    world.controller.paused();
    world.controller.changed();
    await _settle();
    expect(world.git.statusCalls, isEmpty);
    await world.controller.resumed();
    expect(world.git.statusCalls, ['demo']);
  });

  test('a failed status keeps the last one, and says why', () async {
    final world = _World(git: ScriptedGitService(status: _changed('dev', [])));
    await world.start();
    world.git.statusResult = const Err(
      GitFailure('Git took too long', problem: GitProblem.timedOut),
    );
    await world.controller.refresh();
    expect(world.state.kind, GitRepoKind.failed);
    expect(world.state.failure!.problem, GitProblem.timedOut);
    expect(world.state.status!.branch.head, 'dev');
    expect(gitBranchTooltip(world.state), endsWith('Git took too long.'));
  });

  group("the branch chip's words", () {
    GitRepoState repo(GitStatus status) =>
        GitRepoState(kind: GitRepoKind.repository, status: status);

    test('a clean branch up to date with its upstream', () {
      expect(
        gitBranchTooltip(
          repo(
            const GitStatus(
              branch: GitBranchState(
                head: 'main',
                oid: '1234567890',
                upstream: 'origin/main',
                ahead: 0,
                behind: 0,
              ),
            ),
          ),
        ),
        'On branch main. No changes. Up to date with origin/main.',
      );
    });

    test('changes, conflicts, and a branch ahead and behind', () {
      expect(
        gitBranchTooltip(
          repo(
            const GitStatus(
              branch: GitBranchState(
                head: 'main',
                oid: '1234567890',
                upstream: 'origin/main',
                ahead: 2,
                behind: 1,
              ),
              files: [
                GitFileStatus(path: 'a', kind: GitEntryKind.untracked),
                GitFileStatus(
                  path: 'b',
                  kind: GitEntryKind.conflicted,
                  conflict: GitConflict.bothModified,
                ),
              ],
            ),
          ),
        ),
        'On branch main. 2 changed files. 1 conflicted file. 2 ahead of and '
        '1 behind origin/main.',
      );
    });

    test('a detached HEAD, a first commit to come, and a cut listing', () {
      expect(
        gitBranchTooltip(
          repo(
            const GitStatus(
              branch: GitBranchState(oid: 'abcdef1234567'),
              files: [GitFileStatus(path: 'a', kind: GitEntryKind.untracked)],
            ),
          ),
        ),
        'HEAD detached at abcdef1. 1 changed file.',
      );
      expect(
        gitBranchTooltip(
          repo(
            const GitStatus(
              branch: GitBranchState(head: 'main'),
              files: [GitFileStatus(path: 'a', kind: GitEntryKind.untracked)],
              truncated: true,
            ),
          ),
        ),
        'On branch main, no commits yet. More than 1 changed file.',
      );
    });
  });
}
