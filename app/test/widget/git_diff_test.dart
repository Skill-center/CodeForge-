/// Comparing a file from the Source control panel (Phase 7 W5, gate G5's
/// widget part): a tap on a changed file opens it with what changed in it
/// and says what it is compared with, *Stop comparing* leaves the file
/// open, a long press opens the file alone, and a file in a commit opens
/// as that commit left it, read-only, in a tab that says so. The
/// repository is scripted (test/support/scripted_git_service.dart).
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/core/editor/shadow_document.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/memory_file_service.dart';
import '../support/scripted_git_service.dart';
import 'test_harness.dart';

Finder _key(String key) => find.byKey(ValueKey(key));

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkbenchScreen)),
  listen: false,
);

DocumentsState _documents(WidgetTester tester) =>
    _container(tester).read(documentControllerProvider);

GitStatus _status(List<GitFileStatus> files) => GitStatus(
  branch: const GitBranchState(head: 'main', oid: 'a'),
  files: files,
);

GitCommit _commit(String hash) => GitCommit(
  hash: hash * 40,
  parents: ['b' * 40],
  authorName: 'Ada',
  authorEmail: 'ada@example.com',
  authoredAt: DateTime.utc(2026, 11, 5, 14, 3),
  subject: 'The newest',
);

/// The workbench on a wide screen, the Source control panel showing over
/// [git], with `main.js` in the workspace.
Future<MemoryFileService> _panel(
  WidgetTester tester,
  ScriptedGitService git, {
  double width = 1280,
  double height = 800,
}) async {
  final files = MemoryFileService(
    seed: const {'main.js': 'console.log(2)\n', 'notes.md': '# notes\n'},
  );
  setSurface(tester, width, height);
  await tester.pumpWidget(
    TestHarness(
      shell: const ShellState(
        lastRoute: '/workspace',
        activity: ShellActivity.git,
      ),
      files: files,
      git: git,
    ).app(),
  );
  await tester.pumpAndSettle();
  return files;
}

void main() {
  testWidgets('a tap compares the file with the staged version', (
    tester,
  ) async {
    final git =
        ScriptedGitService(
            status: _status(const [
              GitFileStatus(
                path: 'main.js',
                kind: GitEntryKind.tracked,
                workTree: GitChange.modified,
              ),
            ]),
          )
          ..filesAt = {':main.js': 'console.log(1)\n'};
    await _panel(tester, git);

    await tester.tap(_key('git_file_main.js'));
    await tester.pumpAndSettle();
    expect(git.reads, ['file_at :main.js']);
    expect(_documents(tester).openPaths, ['main.js']);
    expect(
      find.text('Showing 1 change against the staged version.'),
      findsOneWidget,
    );

    // Stopping the comparison leaves the file open.
    await tester.tap(find.text('Stop comparing'));
    await tester.pumpAndSettle();
    expect(_key('diff_notice'), findsNothing);
    expect(_documents(tester).openPaths, ['main.js']);
  });

  testWidgets('a long press opens the file with nothing to compare', (
    tester,
  ) async {
    final git =
        ScriptedGitService(
            status: _status(const [
              GitFileStatus(
                path: 'main.js',
                kind: GitEntryKind.tracked,
                workTree: GitChange.modified,
              ),
            ]),
          )
          ..filesAt = {':main.js': 'console.log(1)\n'};
    await _panel(tester, git);

    await tester.longPress(_key('git_file_main.js'));
    await tester.pumpAndSettle();
    expect(git.reads, isEmpty);
    expect(_documents(tester).openPaths, ['main.js']);
    expect(_key('diff_notice'), findsNothing);
  });

  testWidgets("a commit's file opens read-only, in two columns", (
    tester,
  ) async {
    final git =
        ScriptedGitService(status: _status(const []))
          ..commits = [_commit('a')]
          ..commitFilesValue = {
            'a' * 40: const [
              GitCommitFile(path: 'main.js', change: GitChange.modified),
            ],
          }
          ..filesAt = {
            '${'a' * 40}:main.js': 'console.log(2)\n',
            '${'a' * 40}^:main.js': 'console.log(1)\n',
          };
    await _panel(tester, git);

    await tester.tap(_key('git_section_history'));
    await tester.pumpAndSettle();
    await tester.tap(_key('git_commit_aaaaaaa'));
    await tester.pumpAndSettle();
    await tester.tap(_key('git_commit_file_main.js'));
    await tester.pumpAndSettle();

    final key = DocumentRevision.tabKeyFor('main.js', 'a' * 40);
    final documents = _documents(tester);
    expect(documents.openPaths, [key]);
    expect(documents.documents[key]?.readOnly, isTrue);
    expect(documents.documents[key]?.diff?.mode, EditorDiffMode.split);
    // The tab says which commit it is from, and the banner what it is
    // compared with.
    expect(find.text('main.js at aaaaaaa'), findsOneWidget);
    expect(
      find.text('Showing 1 change against the commit before it.'),
      findsOneWidget,
    );
  });

  testWidgets('one column on a phone', (tester) async {
    final git =
        ScriptedGitService(status: _status(const []))
          ..commits = [_commit('a')]
          ..commitFilesValue = {
            'a' * 40: const [
              GitCommitFile(path: 'main.js', change: GitChange.modified),
            ],
          }
          ..filesAt = {
            '${'a' * 40}:main.js': 'console.log(2)\n',
            '${'a' * 40}^:main.js': 'console.log(1)\n',
          };
    await _panel(tester, git, width: 412, height: 915);
    // On a compact phone the panel opens as a sheet from the activity bar.
    if (_key('git_panel').evaluate().isEmpty) {
      await tester.tap(_key('activity_git'));
      await tester.pumpAndSettle();
    }

    await tester.tap(_key('git_section_history'));
    await tester.pumpAndSettle();
    await tester.tap(_key('git_commit_aaaaaaa'));
    await tester.pumpAndSettle();
    await tester.tap(_key('git_commit_file_main.js'));
    await tester.pumpAndSettle();

    final key = DocumentRevision.tabKeyFor('main.js', 'a' * 40);
    expect(
      _documents(tester).documents[key]?.diff?.mode,
      EditorDiffMode.inline,
    );
  });

  testWidgets('a file too large to compare is open, and says so', (
    tester,
  ) async {
    final git =
        ScriptedGitService(
            status: _status(const [
              GitFileStatus(
                path: 'main.js',
                kind: GitEntryKind.tracked,
                workTree: GitChange.modified,
              ),
            ]),
          )
          ..filesAt = {':main.js': 'x\n' * (512 * 1024)};
    await _panel(tester, git);

    await tester.tap(_key('git_file_main.js'));
    await tester.pumpAndSettle();
    expect(_documents(tester).openPaths, ['main.js']);
    expect(find.textContaining('too large to compare here'), findsOneWidget);
  });
}
