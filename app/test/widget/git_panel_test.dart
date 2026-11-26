/// The Source control panel (Phase 7 W4, gate G4's widget part): the
/// branch with its upstream and the remote buttons, the changes in their
/// groups with staging, unstaging and a discard that names the file, the
/// commit box and why it cannot commit, a merge's conflicts with *Mark
/// resolved* and *Abort the merge*, the branches with a new one, a switch
/// and a delete, the history and a commit's files, the explorer's
/// colours, the status strip's chip, and a folder from shared storage
/// offering the import. The repository is scripted
/// (test/support/scripted_git_service.dart).
library;

import 'package:codeforge/application/git/git_controller.dart';
import 'package:codeforge/application/git/git_panel_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/design_system/components/buttons.dart';
import 'package:codeforge/design_system/components/file_tree.dart';
import 'package:codeforge/design_system/tokens/colors.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_storage_broker.dart';
import '../support/scripted_git_service.dart';
import 'test_harness.dart';

const GitIdentity _ada = GitIdentity(
  name: 'Ada Lovelace',
  email: 'ada@example.com',
);

Finder _key(String key) => find.byKey(ValueKey(key));

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkbenchScreen)),
  listen: false,
);

GitFileStatus _file(
  String path, {
  GitChange index = GitChange.unmodified,
  GitChange workTree = GitChange.unmodified,
}) => GitFileStatus(
  path: path,
  kind: GitEntryKind.tracked,
  index: index,
  workTree: workTree,
);

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
  subject: 'a commit',
);

/// A repository on `main`, tracking `origin/main`, with [files] changed.
GitStatus _status(List<GitFileStatus> files, {int ahead = 0, int behind = 0}) =>
    GitStatus(
      branch: GitBranchState(
        head: 'main',
        oid: 'a' * 40,
        upstream: 'origin/main',
        ahead: ahead,
        behind: behind,
      ),
      files: files,
    );

/// The workbench with the Source control panel showing over [git].
Future<void> _panel(WidgetTester tester, ScriptedGitService git) async {
  setSurface(tester, 1280, 800);
  await tester.pumpWidget(
    TestHarness(
      shell: const ShellState(
        lastRoute: '/workspace',
        activity: ShellActivity.git,
      ),
      git: git,
    ).app(),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the branch, its upstream, and the changes in their groups', (
    tester,
  ) async {
    final files = [
      _file('staged.js', index: GitChange.modified),
      _file('changed.js', workTree: GitChange.modified),
      const GitFileStatus(path: 'new.js', kind: GitEntryKind.untracked),
    ];
    final git = ScriptedGitService(status: _status(files, ahead: 2, behind: 1));
    await _panel(tester, git);

    expect(_key('git_panel'), findsOneWidget);
    expect(tester.widget<Text>(_key('git_branch_name_label')).data, 'main');
    expect(
      tester.widget<Text>(_key('git_upstream')).data,
      'origin/main · 2 ahead, 1 behind',
    );
    expect(find.text('CHANGES  3'), findsOneWidget);
    expect(find.text('Staged (1)'), findsOneWidget);
    expect(find.text('Changes (1)'), findsOneWidget);
    expect(find.text('New files (1)'), findsOneWidget);
    expect(_key('git_file_staged.js'), findsOneWidget);
    expect(_key('git_unstage_staged.js'), findsOneWidget);
    expect(_key('git_stage_changed.js'), findsOneWidget);
    expect(_key('git_discard_new.js'), findsOneWidget);
    // A staged row has no discard, an unstaged one no unstage.
    expect(_key('git_discard_staged.js'), findsNothing);
    expect(_key('git_unstage_changed.js'), findsNothing);

    await tester.tap(_key('git_stage_changed.js'));
    await tester.pumpAndSettle();
    await tester.tap(_key('git_unstage_staged.js'));
    await tester.pumpAndSettle();
    await tester.tap(_key('git_stage_all'));
    await tester.pumpAndSettle();
    expect(git.calls, ['stage changed.js', 'unstage staged.js', 'stage_all']);
  });

  testWidgets('a discard names the file, and a new file is deleted', (
    tester,
  ) async {
    final git = ScriptedGitService(
      status: _status([
        _file('src/changed.js', workTree: GitChange.modified),
        const GitFileStatus(path: 'new.js', kind: GitEntryKind.untracked),
      ]),
    );
    await _panel(tester, git);

    await tester.tap(_key('git_discard_src/changed.js'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes to changed.js?'), findsOneWidget);
    expect(find.textContaining('src/changed.js'), findsOneWidget);
    await tester.tap(_key('confirm_cancel'));
    await tester.pumpAndSettle();
    expect(git.calls, isEmpty, reason: 'cancelling changes nothing');

    await tester.tap(_key('git_discard_src/changed.js'));
    await tester.pumpAndSettle();
    await tester.tap(_key('confirm_ok'));
    await tester.pumpAndSettle();
    expect(git.calls, ['discard src/changed.js']);

    // Git does not know an untracked file, so it is deleted instead.
    await tester.tap(_key('git_discard_new.js'));
    await tester.pumpAndSettle();
    expect(find.text('Delete new.js?'), findsOneWidget);
    await tester.tap(_key('confirm_ok'));
    await tester.pumpAndSettle();
    expect(git.calls, ['discard src/changed.js', 'delete_untracked new.js']);
  });

  testWidgets('the commit box says why it cannot commit, then commits', (
    tester,
  ) async {
    final git = ScriptedGitService(status: _status(const []))
      ..identityValue = _ada;
    await _panel(tester, git);

    expect(_key('git_no_changes'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('git_commit_problem')).data,
      'Stage something to commit.',
    );
    expect(tester.widget<CfButton>(_key('git_commit')).onPressed, isNull);

    // Something staged, but nothing written yet.
    git.statusResult = Ok(
      _status([_file('main.js', index: GitChange.modified)]),
    );
    await _container(tester).read(gitControllerProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(_key('git_commit_problem')).data,
      'Write a message for the commit.',
    );

    await tester.enterText(_key('git_commit_message'), 'Add the login screen');
    await tester.pumpAndSettle();
    expect(_key('git_commit_problem'), findsNothing);
    await tester.tap(_key('git_commit'));
    await tester.pumpAndSettle();
    expect(git.calls, ['commit Add the login screen']);
    expect(find.text('Committed.'), findsOneWidget);
    final box = tester.widget<TextField>(_key('git_commit_message'));
    expect(box.controller?.text, '', reason: 'the box is empty again');
  });

  testWidgets('no identity: the box says so before anything runs', (
    tester,
  ) async {
    final git = ScriptedGitService(
      status: _status([_file('main.js', index: GitChange.modified)]),
    )..identityValue = const GitIdentity(name: 'Ada');
    await _panel(tester, git);
    await tester.enterText(_key('git_commit_message'), 'A message');
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(_key('git_commit_problem')).data,
      startsWith('Set your name and email'),
    );
    expect(tester.widget<CfButton>(_key('git_commit')).onPressed, isNull);
    expect(git.calls, isEmpty);
  });

  testWidgets('*Amend* fills in the last commit, and amends with it', (
    tester,
  ) async {
    final git = ScriptedGitService(status: _status(const []))
      ..identityValue = _ada
      ..commits = [_commit('a', 'The last commit')];
    await _panel(tester, git);

    await tester.tap(_key('git_amend'));
    await tester.pumpAndSettle();
    expect(git.reads, ['log 1']);
    final box = tester.widget<TextField>(_key('git_commit_message'));
    expect(box.controller?.text, 'The last commit');
    expect(find.text('Amend'), findsOneWidget);

    await tester.tap(_key('git_commit'));
    await tester.pumpAndSettle();
    expect(git.calls, ['commit --amend The last commit']);
  });

  testWidgets('a merge that stopped: the conflicts, resolved and aborted', (
    tester,
  ) async {
    final git = ScriptedGitService(
      status: _status(const [
        GitFileStatus(
          path: 'main.js',
          kind: GitEntryKind.conflicted,
          conflict: GitConflict.bothModified,
        ),
      ]),
    )..identityValue = _ada;
    await _panel(tester, git);

    expect(find.text('Conflicts (1)'), findsOneWidget);
    expect(find.text('UU'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('git_commit_problem')).data,
      startsWith('The merge has conflicts'),
    );

    // The file opens with its markers in it, as git left them.
    await tester.tap(_key('git_file_main.js'));
    await tester.pumpAndSettle();
    expect(find.text('main.js'), findsWidgets);

    await tester.tap(_key('git_resolve_main.js'));
    await tester.pumpAndSettle();
    expect(git.calls, ['stage main.js']);

    await tester.tap(_key('git_abort_merge'));
    await tester.pumpAndSettle();
    expect(find.text('Abort the merge?'), findsOneWidget);
    await tester.tap(_key('confirm_ok'));
    await tester.pumpAndSettle();
    expect(git.calls, ['stage main.js', 'abort_merge']);
    expect(find.text('The merge was aborted.'), findsOneWidget);
  });

  testWidgets('branches: read when opened, created, switched, deleted', (
    tester,
  ) async {
    final git = ScriptedGitService(status: _status(const []))
      ..branchesValue = [_branch('main', current: true), _branch('dev')];
    await _panel(tester, git);

    // Nothing is read for a section nobody opened.
    expect(git.reads, isEmpty);
    await tester.tap(_key('git_section_branches'));
    await tester.pumpAndSettle();
    expect(git.reads, ['branches']);
    expect(_key('git_branch_main'), findsOneWidget);
    expect(_key('git_branch_dev'), findsOneWidget);
    // The branch checked out cannot be deleted.
    expect(_key('git_delete_branch_main'), findsNothing);
    expect(_key('git_delete_branch_dev'), findsOneWidget);

    await tester.tap(_key('git_branch_dev'));
    await tester.pumpAndSettle();
    expect(git.calls, ['switch dev']);

    // A new branch: git checks the name before the branch is made.
    await tester.tap(_key('git_new_branch'));
    await tester.pumpAndSettle();
    expect(find.text('New branch'), findsOneWidget);
    await tester.enterText(_key('git_branch_name'), 'bad name');
    await tester.tap(_key('git_branch_create'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(_key('git_branch_problem')).data,
      'That is not a valid branch name.',
    );
    expect(git.calls, ['switch dev']);

    await tester.enterText(_key('git_branch_name'), 'feature/login');
    await tester.tap(_key('git_branch_create'));
    await tester.pumpAndSettle();
    expect(git.calls, ['switch dev', 'create_branch feature/login']);
    expect(_key('git_branch_dialog'), findsNothing);
  });

  testWidgets('deleting a branch that is not merged asks again', (
    tester,
  ) async {
    final git = ScriptedGitService(status: _status(const []))
      ..branchesValue = [_branch('main', current: true), _branch('dev')]
      ..operationResult = const Err(
        GitFailure(
          'That branch has commits that are not merged.',
          problem: GitProblem.notFullyMerged,
          operation: 'delete_branch',
        ),
      );
    await _panel(tester, git);
    await tester.tap(_key('git_section_branches'));
    await tester.pumpAndSettle();

    await tester.tap(_key('git_delete_branch_dev'));
    await tester.pumpAndSettle();
    expect(find.text('Delete branch dev?'), findsOneWidget);
    await tester.tap(_key('confirm_ok'));
    await tester.pumpAndSettle();
    expect(git.calls, ['delete_branch dev']);
    expect(find.text('Delete dev anyway?'), findsOneWidget);

    git.operationResult = const Ok(null);
    await tester.tap(_key('confirm_ok'));
    await tester.pumpAndSettle();
    expect(git.calls, ['delete_branch dev', 'delete_branch dev']);
  });

  testWidgets('a switch that would lose changes says why', (tester) async {
    const refused =
        'Your changes would be overwritten. Commit or discard them first.';
    final git = ScriptedGitService(status: _status(const []))
      ..branchesValue = [_branch('main', current: true), _branch('dev')]
      ..operationResult = const Err(
        GitFailure(
          refused,
          problem: GitProblem.localChanges,
          operation: 'switch_branch',
        ),
      );
    await _panel(tester, git);
    await tester.tap(_key('git_section_branches'));
    await tester.pumpAndSettle();
    await tester.tap(_key('git_branch_dev'));
    await tester.pumpAndSettle();
    expect(find.text(refused), findsOneWidget);
  });

  testWidgets("history: the commits, and one commit's files", (tester) async {
    final git = ScriptedGitService(status: _status(const []))
      ..commits = [_commit('a', 'The newest'), _commit('b', 'The older')]
      ..commitFilesValue = {
        'a' * 40: const [
          GitCommitFile(path: 'main.js', change: GitChange.modified),
        ],
      };
    await _panel(tester, git);

    await tester.tap(_key('git_section_history'));
    await tester.pumpAndSettle();
    expect(git.reads, ['log $gitHistoryLength']);
    expect(find.text('The newest'), findsOneWidget);
    expect(find.text('The older'), findsOneWidget);
    expect(find.textContaining('aaaaaaa · Ada · '), findsOneWidget);

    await tester.tap(_key('git_commit_aaaaaaa'));
    await tester.pumpAndSettle();
    expect(git.reads, ['log $gitHistoryLength', 'commit_files ${'a' * 40}']);
    expect(_key('git_commit_sheet'), findsOneWidget);
    expect(_key('git_commit_file_main.js'), findsOneWidget);
    // A tap on a file closes the sheet and opens that file.
    await tester.tap(_key('git_commit_file_main.js'));
    await tester.pumpAndSettle();
    expect(_key('git_commit_sheet'), findsNothing);
  });

  testWidgets('Fetch, Pull and Push run from the panel, with progress', (
    tester,
  ) async {
    final git = ScriptedGitService(status: _status(const []));
    await _panel(tester, git);

    await tester.tap(_key('git_fetch'));
    await tester.pumpAndSettle();
    expect(git.calls, ['fetch']);
    expect(find.text('Fetched.'), findsOneWidget);

    await tester.tap(_key('git_pull'));
    await tester.pumpAndSettle();
    expect(git.calls, ['fetch', 'pull']);

    await tester.tap(_key('git_push'));
    await tester.pumpAndSettle();
    expect(git.calls, ['fetch', 'pull', 'push origin main']);
    expect(find.text('Pushed.'), findsOneWidget);
  });

  testWidgets('a project that is not a repository can become one', (
    tester,
  ) async {
    final git = ScriptedGitService()
      ..statusResult = const Err(
        GitFailure(
          'This project is not a Git repository.',
          problem: GitProblem.notARepository,
          operation: 'status',
        ),
      );
    await _panel(tester, git);
    expect(_key('git_not_a_repository'), findsOneWidget);
    await tester.tap(find.text('Make it a repository'));
    await tester.pumpAndSettle();
    expect(git.calls, ['init main']);
  });

  testWidgets('a folder from shared storage offers the import', (tester) async {
    const uri =
        'content://com.android.externalstorage.documents/tree/primary%3Asite';
    final broker = FakeStorageBroker()
      ..addTree(
        uri,
        'site',
        files: {'main.js': 'console.log(1)\n', '.git/HEAD': 'ref\n'},
      );
    setSurface(tester, 1280, 800);
    await tester.pumpWidget(
      TestHarness(
        broker: broker,
        shell: const ShellState(
          lastRoute: '/workspace',
          activity: ShellActivity.git,
          workspace: FolderLocation(treeUri: uri, name: 'site'),
        ),
        git: ScriptedGitService(),
      ).app(),
    );
    await tester.pumpAndSettle();
    expect(_key('git_folder_state'), findsOneWidget);
    expect(find.text('Git works in projects'), findsOneWidget);

    // The import asks for a name, copies the folder with its .git, and
    // opens the project it made — where Git works.
    await tester.tap(find.text('Import as project'));
    await tester.pumpAndSettle();
    expect(_key('project_name_dialog'), findsOneWidget);
    await tester.tap(_key('project_name_confirm'));
    await tester.pumpAndSettle();
    expect(broker.calls, contains('importFolder'));
    expect(_key('git_folder_state'), findsNothing);
    expect(_key('git_sections'), findsOneWidget);
  });

  testWidgets('the explorer colours the files Git changed', (tester) async {
    final git = ScriptedGitService(
      status: _status(const [
        GitFileStatus(
          path: 'main.js',
          kind: GitEntryKind.tracked,
          workTree: GitChange.modified,
        ),
        GitFileStatus(path: 'src/new.js', kind: GitEntryKind.untracked),
      ]),
    );
    setSurface(tester, 1280, 800);
    await tester.pumpWidget(
      TestHarness(
        shell: const ShellState(lastRoute: '/workspace'),
        git: git,
      ).app(),
    );
    await tester.pumpAndSettle();

    final colors = CfColors.of(tester.element(_key('tree_main.js')));
    final row = tester.widget<CfTreeRow>(_key('tree_main.js'));
    expect(row.stateLetter, 'M');
    expect(row.stateWord, 'modified');
    expect(row.stateColor, colors.warning);
    // The folder over a new file takes its colour, and no letter.
    final folder = tester.widget<CfTreeRow>(_key('tree_src'));
    expect(folder.stateLetter, isNull);
    expect(folder.stateWord, isNull);
    expect(folder.stateColor, colors.success);
    // A file Git says nothing about keeps the plain colour.
    expect(tester.widget<CfTreeRow>(_key('tree_README.md')).stateColor, isNull);
  });

  testWidgets('the branch chip opens the Source control panel', (tester) async {
    final git = ScriptedGitService(status: _status(const []));
    setSurface(tester, 1280, 800);
    await tester.pumpWidget(
      TestHarness(
        shell: const ShellState(lastRoute: '/workspace'),
        git: git,
      ).app(),
    );
    await tester.pumpAndSettle();
    expect(_key('git_panel'), findsNothing);
    await tester.tap(_key('status_branch'));
    await tester.pumpAndSettle();
    expect(_key('git_panel'), findsOneWidget);
  });
}
