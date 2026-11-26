/// Goldens of Phase 7 W4's Source control panel (PHASE_7_PLAN W4: the
/// panel with goldens, as the other panels have): the panel over a
/// repository with staged, changed and new files, its branches and its
/// history open, and the panel of a merge that stopped on conflicts, at
/// 412x915, 800x1280 and 1280x800. Baselines are generated on the CI
/// Linux runner via the [bootstrap] flow, like the screen goldens.
@Tags(['golden'])
library;

import 'package:codeforge/application/git/git_panel_controller.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/scripted_git_service.dart';
import '../widget/test_harness.dart';

const List<(double, double)> _sizes = [(412, 915), (800, 1280), (1280, 800)];

final DateTime _when = DateTime.utc(2026, 11, 5, 14, 3);

GitCommit _commit(String hash, String subject) => GitCommit(
  hash: hash * 40,
  parents: const [],
  authorName: 'Ada Lovelace',
  authorEmail: 'ada@example.com',
  authoredAt: _when,
  subject: subject,
);

GitBranch _branch(String name, {bool current = false, String? upstream}) =>
    GitBranch(
      name: name,
      ref: 'refs/heads/$name',
      kind: GitBranchKind.local,
      oid: 'b' * 40,
      upstream: upstream,
      ahead: upstream == null ? 0 : 2,
      current: current,
      committedAt: _when,
      subject: 'a commit',
    );

/// A repository with work in every group, and its commits.
ScriptedGitService _working() {
  final git = ScriptedGitService(
    status: const GitStatus(
      branch: GitBranchState(
        head: 'feature/login',
        oid: 'a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0',
        upstream: 'origin/feature/login',
        ahead: 2,
        behind: 1,
      ),
      files: [
        GitFileStatus(
          path: 'lib/login.dart',
          kind: GitEntryKind.tracked,
          index: GitChange.modified,
        ),
        GitFileStatus(
          path: 'lib/app.dart',
          kind: GitEntryKind.tracked,
          workTree: GitChange.modified,
        ),
        GitFileStatus(path: 'test/login_test.dart', kind: GitEntryKind.added),
      ],
    ),
  );
  git.identityValue = const GitIdentity(
    name: 'Ada Lovelace',
    email: 'ada@example.com',
  );
  git.branchesValue = [
    _branch('feature/login', current: true, upstream: 'origin/feature/login'),
    _branch('main'),
  ];
  git.commits = [
    _commit('a', 'Add the login screen'),
    _commit('b', 'Move the greeting into its own file'),
  ];
  return git;
}

/// A pull that stopped on conflicts.
ScriptedGitService _conflicted() {
  return ScriptedGitService(
    status: const GitStatus(
      branch: GitBranchState(
        head: 'main',
        oid: 'a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0',
        upstream: 'origin/main',
        ahead: 1,
        behind: 2,
      ),
      files: [
        GitFileStatus(
          path: 'lib/app.dart',
          kind: GitEntryKind.conflicted,
          conflict: GitConflict.bothModified,
        ),
        GitFileStatus(
          path: 'README.md',
          kind: GitEntryKind.conflicted,
          conflict: GitConflict.addedByThem,
        ),
      ],
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  ScriptedGitService git, {
  required double width,
  required double height,
}) async {
  setSurface(tester, width, height);
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
  // On a phone the panel opens as a sheet from the activity bar.
  if (find.byKey(const ValueKey('git_panel')).evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('activity_git')));
    await tester.pumpAndSettle();
  }
}

Future<void> _expectGolden(WidgetTester tester, String file) async {
  expect(tester.takeException(), isNull);
  await expectLater(find.byType(MaterialApp), matchesGoldenFile(file));
  // Let the shell's debounced persistence timer fire before teardown.
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  for (final (width, height) in _sizes) {
    final size = '${width.toInt()}x${height.toInt()}';

    testWidgets('source control panel $size dark', (tester) async {
      await _pump(tester, _working(), width: width, height: height);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkbenchScreen)),
        listen: false,
      );
      final panel = container.read(gitPanelControllerProvider.notifier);
      panel.toggle(GitPanelSection.branches);
      panel.toggle(GitPanelSection.history);
      await tester.pumpAndSettle();
      await _expectGolden(tester, 'git/panel_${size}_dark.png');
    });

    testWidgets('source control conflicts $size dark', (tester) async {
      await _pump(tester, _conflicted(), width: width, height: height);
      await _expectGolden(tester, 'git/conflicts_${size}_dark.png');
    });
  }
}
