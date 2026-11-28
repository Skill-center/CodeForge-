/// Gate G6, the git group (Phase 7 W6; PHASE_7_PLAN W6): Git in the real
/// app on the emulator, on the sealed runtime, against a repository the
/// device serves to itself (git_measure.dart's [GitRemoteServer]: W1's
/// `git http-backend` behind Basic authentication on 127.0.0.1).
///
///   1. A project made a repository from the panel's empty state, the
///      first commit through the commit box, and a branch created and
///      switched to in the branch dialog.
///   2. A file's changes shown as a diff (a tap in the panel), one change
///      reverted in the page (`cmd.exec revertChunk`, the diff button's
///      own edit), the file saved and committed: what the commit holds is
///      what the revert left.
///   3. A clone from the local server with the token typed into the
///      credential dialog and remembered; a push the server really gets;
///      a pull that conflicts, resolved and committed as a merge.
///   4. The token found nowhere: not in the app's files or logs, the
///      runtime's home, the project, or any process's arguments or
///      environment — looked for while git ran, and after it.
///   5. The 10,000-file repository: the status as the panel refreshes it,
///      the commit, and Flutter's frames meanwhile — none frozen.
///
/// Nothing waits for the app to settle: a status spinner or a progress
/// bar is almost always on screen here, and `pumpAndSettle` would never
/// return. The figures are recorded, never judged in this group — the
/// budgets are the phone's (phone_git_test.dart, which Test Lab runs and
/// judges). The gate reads the GIT_GATE lines (tool/ci/emulator_gate.sh).
library;

import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/git/git_controller.dart';
import 'package:codeforge/application/git/git_panel_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/storage/drift_session_store.dart'
    show appDatabaseFileName;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'git_measure.dart';
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

void _report(String line) => debugPrint('GIT_GATE $line');

/// The project the local work happens in, the one the clone lands in,
/// and the large one.
const String _project = 'git-gate';
const String _clone = 'git-gate-clone';
const String _large = 'git-gate-large';

const String _notes = 'notes.md';
const String _notesFirst = '''
# Notes

one
two
three
''';

/// Two changes against the commit: the word on one line, and a line at
/// the end. The gate reverts the first and commits the second.
const String _notesEdited = '''
# Notes

ONE
two
three
four
''';

/// What is left once the first change is reverted.
const String _notesReverted = '''
# Notes

one
two
three
four
''';

/// The file both sides change, so that the pull conflicts.
const String _shared = 'README.md';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'git: a repository made, committed and branched; a diff reverted and '
    'committed; a clone with a token, a push and a conflicting pull; the '
    'token nowhere; the 10,000-file repository',
    timeout: const Timeout(Duration(minutes: 40)),
    (tester) async {
      final binding = tester.binding as IntegrationTestWidgetsFlutterBinding;
      // A clean slate: no session database, no project from an earlier
      // attempt, no remembered anything.
      final appFiles = await applicationFilesPath();
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$appFiles/$appDatabaseFileName$suffix');
        if (file.existsSync()) {
          file.deleteSync();
        }
      }
      final projects = Directory(await projectsRootPath());
      if (projects.existsSync()) {
        projects.deleteSync(recursive: true);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await pumpRealApp(tester, prefs);
      await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CodeForgeApp)),
        listen: false,
      );
      // The workbench starts the runtime, as it does for the user.
      await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('explore_demo')));
      await tester.pump();
      await pumpUntil(
        tester,
        () {
          final status = container.read(runtimeControllerProvider);
          return (status.usable && !status.auditing) ||
              status.state == RuntimeState.failed ||
              status.state == RuntimeState.unavailable;
        },
        what: 'the runtime to be ready',
        timeout: const Duration(minutes: 12),
      );
      final runtime = container.read(runtimeControllerProvider);
      expect(runtime.state, RuntimeState.ready, reason: runtime.detail);

      final runtimeService = container.read(runtimeServiceProvider);
      final git = container.read(gitServiceProvider);
      expect(git.available, isTrue, reason: 'git runs on this build');
      final documents = container.read(documentControllerProvider.notifier);
      final host = container.read(editorHostProvider);
      // Every tap, every wait: git_measure.dart's driver, shared with the
      // phone's budgets (phone_git_test.dart).
      final app = await GitDriver.of(tester, container);

      // Commits are made by somebody: the identity the runtime's git
      // shares, set once for every repository in this run.
      final named = await git.setIdentity(
        const GitIdentity(name: gateName, email: gateEmail),
      );
      expect(named.isOk, isTrue, reason: '$named');

      // ── 1. A repository, a commit, a branch ────────────────────────────
      final localRoot = await app.openProject(_project);
      File('$localRoot/$_notes').writeAsStringSync(_notesFirst);
      File('$localRoot/$_shared').writeAsStringSync('first\n');
      await app.openPanel();
      await pumpUntil(
        tester,
        () => app.repo.kind == GitRepoKind.notARepository,
        what: 'the panel to say the project is not a repository yet',
        timeout: const Duration(seconds: 90),
      );
      expect(app.shown('git_not_a_repository'), isTrue);
      final initWatch = Stopwatch()..start();
      await app.tapText('Make it a repository');
      await pumpUntil(
        tester,
        () => app.repo.kind == GitRepoKind.repository,
        what: 'the project to become a repository',
      );
      final initMs = initWatch.elapsedMilliseconds;
      await app.statusWhere(
        (status) => status.untracked.length == 2,
        what: 'the two files to be listed as untracked',
      );
      expect(app.repo.status!.branch.head, 'main');
      expect(app.repo.status!.branch.unborn, isTrue);

      final commitWatch = Stopwatch()..start();
      await app.commitEverything('The first commit');
      final firstCommitMs = commitWatch.elapsedMilliseconds;
      expect(app.repo.status!.branch.unborn, isFalse);
      _report(
        'init ms=$initMs branch=${app.repo.status!.branch.head} '
        'first_commit_ms=$firstCommitMs',
      );

      // The branch dialog: created and switched to in one go.
      await app.openPanel();
      await app.tap('git_section_branches');
      await app.waitFor('git_new_branch');
      await app.tap('git_new_branch');
      await app.waitFor('git_branch_dialog');
      await app.type('git_branch_name', 'work');
      await app.tap('git_branch_create');
      await pumpUntil(
        tester,
        () => app.repo.status?.branch.head == 'work',
        what: 'the new branch to be checked out',
      );
      final branches = container.read(gitPanelControllerProvider).localBranches;
      _report(
        'branch head=${app.repo.status!.branch.head} '
        'branches=${branches.length}',
      );

      // ── 2. A diff, a change reverted, the file committed ───────────────
      File('$localRoot/$_notes').writeAsStringSync(_notesEdited);
      await app.control.refresh();
      await app.statusWhere(
        (status) => status.unstaged.any((file) => file.path == _notes),
        what: 'the edited file to be listed',
      );
      await app.openPanel();
      await app.tap('git_file_$_notes');
      await pumpUntil(tester, () {
        final state = container.read(documentControllerProvider);
        return state.activePath == _notes &&
            state.documents[_notes]?.diff != null;
      }, what: "the file's diff to open");
      await app.closePanel();
      final diff = container
          .read(documentControllerProvider)
          .documents[_notes]!
          .diff!;
      expect(diff.chunks, 2, reason: 'two changes against the commit');
      expect(diff.against, 'the staged version');
      expect(app.shown('diff_notice'), isTrue);
      expect(find.textContaining('Showing 2 changes against'), findsOneWidget);

      // The page reverts the change the cursor is in — the same edit the
      // diff's own *Revert this change* button makes (Phase 7 W6's
      // `revertChunk`), so the gate can do what a finger does.
      final docId = container
          .read(documentControllerProvider)
          .documents[_notes]!
          .docId;
      expect((await host.gotoLine(1)).isOk, isTrue);
      expect((await host.exec('revertChunk')).isOk, isTrue);
      await pumpUntil(
        tester,
        () => host.textOf(docId) == _notesReverted,
        what: 'the first change to go back',
      );
      final saved = await documents.save(_notes);
      expect(saved.isOk, isTrue, reason: '$saved');
      expect(File('$localRoot/$_notes').readAsStringSync(), _notesReverted);
      await app.control.refresh();
      await app.commitEverything('Keep the fourth line only');
      final committed = await git.fileAt(_project, _notes, revision: 'HEAD');
      expect(committed.valueOrNull, _notesReverted);
      _report(
        'diff chunks=${diff.chunks} against="${diff.against}" reverted=1 '
        'committed_chars=${committed.valueOrNull?.length}',
      );

      // ── 3. A clone with a token, a push, a conflicting pull ────────────
      final token = freshToken();
      final server = await GitRemoteServer.start(
        runtimeService,
        user: serverUser,
        token: token,
        seed: const {_shared: 'served\n'},
      );
      _report('server port=${server.port} start_ms=${server.startMs}');
      var credentialAsks = 0;
      var cloneFrozen = -1;
      final cloneRoot = '${projects.path}/$_clone';
      try {
        await app.closePanel();
        await app.tap('workbench_home');
        await app.waitFor('clone_repository');
        await app.tap('clone_repository');
        await app.waitFor('clone_dialog');
        await app.type('clone_url', server.url);
        await app.type('clone_name', _clone);

        /// The credential dialog, answered with the run's token and
        /// *Remember on this device* left on.
        Future<void> signIn() async {
          await app.waitFor(
            'git_credential_dialog',
            timeout: const Duration(seconds: 120),
          );
          credentialAsks += 1;
          await app.type('git_credential_user', serverUser);
          await app.type('git_credential_token', token);
          expect(
            tester
                .widget<CheckboxListTile>(
                  find.byKey(const ValueKey('git_credential_remember')),
                )
                .value,
            isTrue,
            reason: 'the token is remembered by default',
          );
          await app.tap('git_credential_confirm');
        }

        final cloneWatch = Stopwatch()..start();
        await app.tap('clone_confirm');
        final (_, cloneFrames) = await measureFrames(tester, binding, () async {
          await signIn();
          await pumpUntil(
            tester,
            () => Directory('$cloneRoot/.git').existsSync(),
            what: 'the clone to land',
            timeout: const Duration(minutes: 4),
          );
          await pumpUntil(
            tester,
            () => app.repo.project == _clone,
            what: 'the clone to open as the workspace',
            timeout: const Duration(minutes: 2),
          );
        });
        final cloneMs = cloneWatch.elapsedMilliseconds;
        cloneFrozen = cloneFrames.frozen;
        expect(credentialAsks, 1);
        expect(File('$cloneRoot/$_shared').readAsStringSync(), 'served\n');
        _report(
          'clone ms=$cloneMs asked=$credentialAsks '
          'frames=${cloneFrames.frames} slow=${cloneFrames.slow} '
          'slow_pct=${cloneFrames.slowPct} frozen=${cloneFrames.frozen} '
          'p95_ms=${cloneFrames.p95TotalMs} '
          'under_budget=${cloneFrames.underBudget ? 1 : 0}',
        );

        // The push: the stored token signs in, so nothing is asked again,
        // and the server really has the commit afterwards.
        File('$cloneRoot/$_shared').writeAsStringSync('served\nfrom the app\n');
        await app.control.refresh();
        await app.commitEverything('From the device');
        final pushWatch = Stopwatch()..start();
        await app.openPanel();
        await app.tap('git_push');
        await app.waitGone('git_progress_dialog');
        final pushMs = pushWatch.elapsedMilliseconds;
        expect(credentialAsks, 1, reason: 'the token was remembered');
        expect(await server.servedLog('%s'), 'From the device');
        expect(await server.servedFile(_shared), 'served\nfrom the app\n');
        await app.statusWhere(
          (status) => status.branch.upstream != null,
          what: 'the branch to have an upstream',
        );
        _report(
          'push ms=$pushMs asked=$credentialAsks '
          'upstream=${app.repo.status!.branch.upstream}',
        );

        // The pull: somebody else changed the same line, so it conflicts.
        await server.commitElsewhere(
          _shared,
          'served\nfrom somebody else\n',
          message: 'From somebody else',
        );
        File('$cloneRoot/$_shared').writeAsStringSync('served\nmine again\n');
        await app.control.refresh();
        await app.commitEverything('Mine again');
        final pullWatch = Stopwatch()..start();
        await app.openPanel();
        await app.tap('git_pull');
        await app.waitGone('git_progress_dialog');
        final pullMs = pullWatch.elapsedMilliseconds;
        await app.statusWhere(
          (status) => status.conflicted.isNotEmpty,
          what: 'the conflict to be listed',
        );
        expect(
          File('$cloneRoot/$_shared').readAsStringSync(),
          contains('<<<<<<<'),
        );
        await app.openPanel();
        await app.reveal('git_abort_merge');
        expect(
          app.shown('git_abort_merge'),
          isTrue,
          reason: 'a merge that stopped can be abandoned',
        );
        // Resolved as the user would: both lines kept, no markers left.
        File(
          '$cloneRoot/$_shared',
        ).writeAsStringSync('served\nfrom the app\nfrom somebody else\n');
        await app.control.refresh();
        await app.openPanel();
        await app.tap('git_resolve_$_shared');
        await app.statusWhere(
          (status) => status.conflicted.isEmpty && status.staged.isNotEmpty,
          what: 'the file to be marked resolved',
        );
        await app.type('git_commit_message', 'Merge the two lines');
        await app.tap('git_commit');
        await app.statusWhere(
          (status) => status.staged.isEmpty && status.conflicted.isEmpty,
          what: 'the merge to be committed',
        );
        final shownParents = await runtimeOk(runtimeService, 'git', [
          ...gitHousekeeping,
          'log',
          '-1',
          '--format=%P',
        ], directory: cloneRoot);
        final parents = shownParents.stdout.trim().split(RegExp(r'\s+'));
        expect(
          parents.length,
          2,
          reason: 'a merge commit has two parents: ${shownParents.stdout}',
        );
        _report(
          'pull ms=$pullMs conflicted=1 resolved=1 '
          'merge_parents=${parents.length}',
        );

        // ── 4. The token, looked for everywhere ──────────────────────────
        // A fetch runs while the processes are swept: git, its credential
        // helper and the server are all up meanwhile.
        final (_, sweep) = await sweepWhile(
          token,
          [
            projects.path,
            await noBackupFilesPath(),
            await runtimeHome(runtimeService),
          ],
          () async {
            await app.openPanel();
            await app.tap('git_fetch');
            await app.waitGone('git_progress_dialog');
            await app.closePanel();
          },
        );
        _report(sweep.line());
        expect(
          sweep.files,
          isEmpty,
          reason: 'the token is in no file: ${sweep.files}',
        );
        expect(
          sweep.processes,
          isEmpty,
          reason: 'the token is in no process: ${sweep.processes}',
        );
        expect(sweep.gitSeen, greaterThan(0), reason: 'git ran while swept');
        expect(credentialAsks, 1, reason: 'the token was asked for once');
      } finally {
        await server.stop();
      }

      // ── 5. The 10,000-file repository ──────────────────────────────────
      await app.closePanel();
      final largeRoot = await app.openProject(_large);
      final writtenMs = writeLargeRepository(largeRoot);
      final made = await app.control.init();
      expect(made.isOk, isTrue, reason: 'init the large repository: $made');
      await pumpUntil(
        tester,
        () => app.repo.kind == GitRepoKind.repository,
        what: 'the large project to become a repository',
        timeout: const Duration(minutes: 3),
      );
      final untracked = await measureStatuses(
        tester,
        container,
        'untracked',
        files: largeFileCount,
        samples: 5,
      );
      _report(untracked.line());
      final (_, commitFrames) = await measureFrames(tester, binding, () async {
        await app.openPanel();
        await app.waitFor('git_stage_all');
        await app.tap('git_stage_all');
        await app.statusWhere(
          (status) => status.staged.isNotEmpty && status.untracked.isEmpty,
          what: 'the large repository to be staged',
          timeout: const Duration(minutes: 8),
        );
        await app.type('git_commit_message', 'Ten thousand files');
        await app.tap('git_commit');
        await app.statusWhere(
          (status) => status.staged.isEmpty,
          what: 'the large commit to be made',
          timeout: const Duration(minutes: 8),
        );
        await app.closePanel();
      });
      _report(
        'large files=$largeFileCount written_ms=$writtenMs '
        'commit_frames=${commitFrames.frames} slow=${commitFrames.slow} '
        'slow_pct=${commitFrames.slowPct} frozen=${commitFrames.frozen} '
        'p95_ms=${commitFrames.p95TotalMs} '
        'under_budget=${commitFrames.underBudget ? 1 : 0}',
      );
      final (clean, statusFrames) = await measureFrames(
        tester,
        binding,
        () =>
            measureStatuses(tester, container, 'clean', files: largeFileCount),
      );
      _report(clean.line());
      _report(
        'large_status_frames frames=${statusFrames.frames} '
        'slow=${statusFrames.slow} slow_pct=${statusFrames.slowPct} '
        'frozen=${statusFrames.frozen} p95_ms=${statusFrames.p95TotalMs} '
        'longest_gap_ms=${statusFrames.longestGapMs} '
        'under_budget=${statusFrames.underBudget ? 1 : 0}',
      );
      expect(statusFrames.frozen, 0, reason: 'no frozen frame while a status');
      expect(commitFrames.frozen, 0, reason: 'no frozen frame while a commit');
      expect(cloneFrozen, 0, reason: 'no frozen frame while a clone');

      // A hundred files changed, as a working day leaves them.
      for (var file = 0; file < filesPerFolder; file++) {
        final name = 'd0000/f${file.toString().padLeft(2, '0')}.txt';
        File('$largeRoot/$name').writeAsStringSync('changed\n');
      }
      final changed = await measureStatuses(
        tester,
        container,
        'changed',
        files: largeFileCount,
        samples: 10,
      );
      _report(changed.line());
      expect(app.repo.status!.changeCount, filesPerFolder);
    },
  );
}
