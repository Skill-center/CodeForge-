/// The status strip's branch chip (Phase 7 W2, PHASE_7_PLAN W2): the open
/// project's branch, a `*` with changes, its words for TalkBack and the
/// tooltip, and no chip at all where there is no repository or no Git.
library;

import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/design_system/components/feedback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/scripted_git_service.dart';
import 'test_harness.dart';

final Finder _chip = find.byKey(const ValueKey('status_branch'));

Future<void> _open(WidgetTester tester, TestHarness harness) async {
  setSurface(tester, 1280, 800);
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  await openDemoWorkspace(tester);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no Git here: no chip', (tester) async {
    await _open(tester, TestHarness());
    expect(_chip, findsNothing);
  });

  testWidgets("a repository's branch, with a star for its changes", (
    tester,
  ) async {
    final git = ScriptedGitService(
      status: GitStatus(
        branch: GitBranchState(
          head: 'feature/login',
          oid: 'a' * 40,
          upstream: 'origin/feature/login',
          ahead: 1,
          behind: 0,
        ),
        files: const [
          GitFileStatus(
            path: 'main.js',
            kind: GitEntryKind.tracked,
            workTree: GitChange.modified,
          ),
        ],
      ),
    );
    await _open(tester, TestHarness(git: git));
    expect(git.statusCalls, contains('demo'));
    final chip = tester.widget<CfStatusChip>(_chip);
    expect(chip.label, 'feature/login*');
    expect(
      chip.tooltip,
      'On branch feature/login. 1 changed file. 1 ahead of and 0 behind '
      'origin/feature/login.',
    );
    expect(chip.color, isNull);
  });

  testWidgets('a clean branch has no star', (tester) async {
    await _open(tester, TestHarness(git: ScriptedGitService()));
    final chip = tester.widget<CfStatusChip>(_chip);
    expect(chip.label, 'main');
    expect(chip.tooltip, 'On branch main. No changes.');
  });

  testWidgets('conflicts colour the chip', (tester) async {
    final git = ScriptedGitService(
      status: const GitStatus(
        branch: GitBranchState(head: 'main', oid: '1234567'),
        files: [
          GitFileStatus(
            path: 'a.txt',
            kind: GitEntryKind.conflicted,
            conflict: GitConflict.bothModified,
          ),
        ],
      ),
    );
    await _open(tester, TestHarness(git: git));
    final chip = tester.widget<CfStatusChip>(_chip);
    expect(chip.label, 'main*');
    expect(chip.color, isNotNull);
    expect(chip.tooltip, contains('1 conflicted file'));
  });

  testWidgets('a project that is not a repository has no chip', (tester) async {
    final git = ScriptedGitService()
      ..statusResult = const Err(
        GitFailure('Not a repository', problem: GitProblem.notARepository),
      );
    await _open(tester, TestHarness(git: git));
    expect(git.statusCalls, contains('demo'));
    expect(_chip, findsNothing);
  });
}
