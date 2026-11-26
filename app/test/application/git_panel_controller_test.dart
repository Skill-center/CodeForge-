/// What the Source control panel reads (Phase 7 W4, gate G4): sections
/// read only once they are open and only once, a new branch state reads
/// them again, the identity comes from the host, *Amend* fills the last
/// commit's message in, a commit empties the box, and [commitProblem]
/// says in one sentence why a commit cannot run.
library;

import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/git/git_controller.dart';
import 'package:codeforge/application/git/git_panel_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
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

Future<void> _settle() async {
  await Future<void>.delayed(_debounce * 3);
  await _drain();
}

GitCommit _commit(String hash, String subject) => GitCommit(
  hash: hash * 40,
  parents: const [],
  authorName: 'Ada',
  authorEmail: 'ada@example.com',
  authoredAt: DateTime.utc(2026, 11, 5, 14, 3),
  subject: subject,
);

GitBranch _branch(String name, {bool current = false}) => GitBranch(
  name: name,
  ref: 'refs/heads/$name',
  kind: GitBranchKind.local,
  oid: 'b' * 40,
  current: current,
  subject: 'the last commit',
);

final class _World {
  _World({ScriptedGitService? git}) : git = git ?? ScriptedGitService() {
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
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final MemoryFileService files = MemoryFileService();
  final ScriptedGitService git;
  final FakeRuntimeService runtime = FakeRuntimeService(
    state: RuntimeState.ready,
  );
  final List<FakeEditorSurface> pages = [];
  late final ProviderContainer container;

  GitPanelController get panel =>
      container.read(gitPanelControllerProvider.notifier);

  GitPanelState get state => container.read(gitPanelControllerProvider);

  GitRepoState get repo => container.read(gitControllerProvider);

  Future<void> start() async {
    container.listen(gitControllerProvider, (previous, next) {});
    container.listen(gitPanelControllerProvider, (previous, next) {});
    await container.read(editorHostProvider).start();
    await container.read(runtimeControllerProvider.notifier).refresh();
    await _settle();
  }
}

void main() {
  test('a section reads what it shows when it opens, and only once', () async {
    final git = ScriptedGitService()
      ..branchesValue = [_branch('main', current: true), _branch('dev')]
      ..commits = [_commit('a', 'the newest'), _commit('b', 'the older')];
    final world = _World(git: git);
    await world.start();
    // Changes is open from the start and is the status: no read of its own.
    expect(world.state.open, {GitPanelSection.changes});
    expect(git.reads, isEmpty);

    world.panel.toggle(GitPanelSection.branches);
    await _drain();
    expect(git.reads, ['branches']);
    expect(world.state.branches.length, 2);
    expect(world.state.localBranches.map((b) => b.name), ['main', 'dev']);

    // Opening it again, after closing it, reads nothing: it is still fresh.
    world.panel
      ..toggle(GitPanelSection.branches)
      ..toggle(GitPanelSection.branches);
    await _drain();
    expect(git.reads, ['branches']);

    world.panel.toggle(GitPanelSection.history);
    await _drain();
    expect(git.reads, ['branches', 'log $gitHistoryLength']);
    expect(world.state.history.map((c) => c.subject), [
      'the newest',
      'the older',
    ]);
  });

  test('a commit on the branch reads the open sections again', () async {
    final git = ScriptedGitService()..branchesValue = [_branch('main')];
    final world = _World(git: git);
    await world.start();
    world.panel.toggle(GitPanelSection.branches);
    await _drain();
    expect(git.reads, ['branches']);

    // The status comes back with another commit on the branch.
    git
      ..statusResult = const Ok(
        GitStatus(branch: GitBranchState(head: 'main', oid: 'c')),
      )
      ..branchesValue = [_branch('main'), _branch('dev')];
    await world.container.read(gitControllerProvider.notifier).refresh();
    await _settle();
    expect(git.reads, ['branches', 'branches']);
    expect(world.state.localBranches.length, 2);

    // A status that changes nothing about the branch reads nothing again.
    await world.container.read(gitControllerProvider.notifier).refresh();
    await _settle();
    expect(git.reads, ['branches', 'branches']);
  });

  test('a read that fails says so and keeps what was read before', () async {
    final git = ScriptedGitService()..branchesValue = [_branch('main')];
    final world = _World(git: git);
    await world.start();
    world.panel.toggle(GitPanelSection.branches);
    await _drain();

    git
      ..branchesFailure = const GitFailure(
        'Git is busy with this repository.',
        problem: GitProblem.busy,
        operation: 'branches',
      )
      ..statusResult = const Ok(
        GitStatus(branch: GitBranchState(head: 'other', oid: 'c')),
      );
    await world.container.read(gitControllerProvider.notifier).refresh();
    await _settle();
    expect(
      world.state.failures[GitPanelSection.branches]?.problem,
      GitProblem.busy,
    );
    expect(world.state.localBranches.map((b) => b.name), ['main']);
  });

  test('the identity is read once the repository is there', () async {
    final git = ScriptedGitService()
      ..identityValue = const GitIdentity(name: 'Ada', email: 'ada@x.test');
    final world = _World(git: git);
    await world.start();
    expect(world.state.identity?.name, 'Ada');
  });

  test('Amend fills in the last commit message, and a commit empties the '
      'box', () async {
    final git = ScriptedGitService(
      status: const GitStatus(
        branch: GitBranchState(head: 'main', oid: 'a'),
        files: [
          GitFileStatus(
            path: 'main.js',
            kind: GitEntryKind.tracked,
            index: GitChange.modified,
          ),
        ],
      ),
    )..commits = [_commit('a', 'the last commit')];
    final world = _World(git: git);
    await world.start();

    await world.panel.setAmend(true);
    await _drain();
    expect(world.state.amend, isTrue);
    expect(world.state.message, 'the last commit');
    expect(git.reads, ['log 1']);

    // What the user typed is never replaced.
    await world.panel.setAmend(false);
    world.panel.setMessage('mine');
    await world.panel.setAmend(true);
    await _drain();
    expect(world.state.message, 'mine');

    final committed = await world.panel.commit();
    expect(committed, isA<Ok<void>>());
    expect(git.calls, contains('commit --amend mine'));
    expect(world.state.message, '');
    expect(world.state.amend, isFalse);
  });

  test('a commit that fails keeps the message to try again', () async {
    final git = ScriptedGitService()
      ..operationResult = const Err(
        GitFailure(
          'There is nothing to commit.',
          problem: GitProblem.nothingToCommit,
          operation: 'commit',
        ),
      );
    final world = _World(git: git);
    await world.start();
    world.panel.setMessage('a message');
    final result = await world.panel.commit();
    expect(result, isA<Err<void>>());
    expect(world.state.message, 'a message');
  });

  test('why a commit cannot run, in one sentence', () {
    const repo = GitRepoState(
      kind: GitRepoKind.repository,
      project: 'demo',
      status: GitStatus(branch: GitBranchState(head: 'main', oid: 'a')),
    );
    const staged = GitRepoState(
      kind: GitRepoKind.repository,
      project: 'demo',
      status: GitStatus(
        branch: GitBranchState(head: 'main', oid: 'a'),
        files: [
          GitFileStatus(
            path: 'main.js',
            kind: GitEntryKind.tracked,
            index: GitChange.modified,
          ),
        ],
      ),
    );
    const conflicted = GitRepoState(
      kind: GitRepoKind.repository,
      project: 'demo',
      status: GitStatus(
        branch: GitBranchState(head: 'main', oid: 'a'),
        files: [
          GitFileStatus(
            path: 'main.js',
            kind: GitEntryKind.conflicted,
            conflict: GitConflict.bothModified,
          ),
        ],
      ),
    );
    const unborn = GitRepoState(
      kind: GitRepoKind.repository,
      project: 'demo',
      status: GitStatus(branch: GitBranchState(head: 'main')),
    );
    const withMessage = GitPanelState(message: 'a message');

    expect(
      commitProblem(const GitRepoState(), const GitPanelState()),
      'Git has not read this repository yet.',
    );
    expect(
      commitProblem(conflicted, withMessage),
      startsWith('The merge has conflicts'),
    );
    expect(commitProblem(repo, withMessage), 'Stage something to commit.');
    expect(
      commitProblem(staged, const GitPanelState()),
      'Write a message for the commit.',
    );
    expect(commitProblem(staged, withMessage), isNull);
    expect(
      commitProblem(
        staged,
        const GitPanelState(
          message: 'a message',
          identity: GitIdentity(name: 'Ada'),
        ),
      ),
      startsWith('Set your name and email'),
    );
    // Amending needs no staged file, and keeps the last message when the
    // box is empty; with no commit at all it says so.
    expect(commitProblem(repo, const GitPanelState(amend: true)), isNull);
    expect(
      commitProblem(unborn, const GitPanelState(amend: true)),
      'This repository has no commits yet.',
    );
  });

  test('nothing is read where there is no repository', () async {
    final git = ScriptedGitService()
      ..statusResult = const Err(
        GitFailure(
          'This project is not a Git repository.',
          problem: GitProblem.notARepository,
          operation: 'status',
        ),
      );
    final world = _World(git: git);
    await world.start();
    expect(world.repo.kind, GitRepoKind.notARepository);
    world.panel
      ..toggle(GitPanelSection.branches)
      ..toggle(GitPanelSection.history);
    await _drain();
    expect(git.reads, isEmpty);
    expect(world.state.identity, isNull);
    final files = await world.panel.commitFiles('a' * 40);
    expect(files, isA<Err<List<GitCommitFile>>>());
  });

  test("a commit's files come from the host", () async {
    final git = ScriptedGitService()
      ..commitFilesValue = {
        'a' * 40: const [
          GitCommitFile(path: 'main.js', change: GitChange.modified),
        ],
      };
    final world = _World(git: git);
    await world.start();
    final files = await world.panel.commitFiles('a' * 40);
    expect(files, isA<Ok<List<GitCommitFile>>>());
    expect((files as Ok<List<GitCommitFile>>).value.single.path, 'main.js');
    expect(git.reads, ['commit_files ${'a' * 40}']);
  });
}
