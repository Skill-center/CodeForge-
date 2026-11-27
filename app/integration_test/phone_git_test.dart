/// Git's budgets on a phone (Phase 7 W6, gate G6; PHASE_7_PLAN §10 item
/// 4, the owner's decision of 2026-11-23), in the real app on the sealed
/// runtime, against a repository the phone serves to itself
/// (git_measure.dart's [GitRemoteServer]):
///
/// - **The status of 10,000 files** within 500 ms at the 95th percentile,
///   as the panel refreshes it ([measureStatuses]): untracked, then clean,
///   then with a hundred files changed, as a working day leaves them.
/// - **The frames** while a status, a commit and a clone run
///   ([measureFrames]): the terminal flood's rule, at most 5 % of frames
///   over 32 ms and none frozen. The progress bar laid over the app makes
///   Flutter draw every frame, so nothing hides behind an idle screen.
/// - **The clone and the memory**, recorded: the 10,000-file repository
///   cloned over HTTP from the device's own server, with the token typed
///   into the credential dialog once, and the app's and its renderers'
///   PSS before and after (through the gate: folder_gate.dart).
///
/// Firebase Test Lab runs it on its arm64 phone in the same entrypoint as
/// the store, search, the terminal and the languages (sync_modes_test.dart
/// calls [phoneGitTests]). The figures go to the device log as
/// `RUNTIME_GATE git_phone_*` lines, which tool/ci/gate_results.py holds
/// to the budgets (`--require`), and as a CODEFORGE_GIT_JSON document.
/// The emulator gate's own git group runs git_test.dart instead: the same
/// work with the whole of Git's screen behind it, recorded and never
/// judged (app/tool/ci/emulator_gate.sh).
///
/// Nothing here waits for the app to settle: a status spinner or a
/// progress bar is almost always on screen, and `pumpAndSettle` would
/// never return.
library;

import 'dart:async';
import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/git/git_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/git/git_models.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_gate.dart';
import 'git_measure.dart';
import 'smoke_test.dart' show pumpRealApp, pumpUntil;
import 'terminal_measure.dart'
    show
        MemorySample,
        UiFrames,
        buildMode,
        frozenFrameMs,
        memoryFrom,
        printReport,
        slowFrameBudgetPct,
        slowFrameMs;

/// A figure for tool/ci/gate_results.py, straight to the device log.
void _figure(String key, Object value) =>
    Zone.root.print('RUNTIME_GATE git_phone_$key=$value');

/// A line of evidence, as the emulator gate's git group writes them.
void _line(String text) => debugPrint('GIT_GATE phone $text');

/// The repository the budgets are measured in, and the clone of it.
const String _large = 'git-phone-large';
const String _clone = 'git-phone-clone';

/// Frames, as a figure and as a line.
void _frames(String label, UiFrames frames) {
  _figure('${label}_frames', frames.frames);
  _figure('${label}_slow_pct', frames.slowPct);
  _figure('${label}_frozen', frames.frozen);
  _figure('${label}_p95_ms', frames.p95TotalMs);
  _figure('${label}_under_budget', frames.underBudget ? 1 : 0);
  _line(
    'frames_$label frames=${frames.frames} slow=${frames.slow} '
    'slow_pct=${frames.slowPct} frozen=${frames.frozen} '
    'p95_ms=${frames.p95TotalMs} max_ms=${frames.maxTotalMs} '
    'longest_gap_ms=${frames.longestGapMs} '
    'under_budget=${frames.underBudget ? 1 : 0}',
  );
}

/// A run of statuses, as figures and as a line.
void _statuses(String label, StatusFigures figures) {
  _figure('status_${label}_p50_ms', figures.p50Ms);
  _figure('status_${label}_p95_ms', figures.p95Ms);
  _figure('status_${label}_max_ms', figures.maxMs);
  _figure('status_${label}_under_budget', figures.underBudget ? 1 : 0);
  _line(figures.line());
}

void phoneGitTests() {
  testWidgets(
    'git: 10,000 files, their commit and a clone of them on a phone (G6)',
    timeout: const Timeout(Duration(minutes: 25)),
    (tester) async {
      final binding = tester.binding as IntegrationTestWidgetsFlutterBinding;
      final gate = await FolderGate.start();
      final memory = memoryFrom(
        (request) => gate.ask(request, timeout: const Duration(seconds: 90)),
      );
      // A clean slate: no project from an earlier test, nothing remembered.
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
      // Commits are made by somebody: the identity the runtime's git
      // shares, set once for every repository in this run.
      final named = await git.setIdentity(
        const GitIdentity(name: gateName, email: gateEmail),
      );
      expect(named.isOk, isTrue, reason: '$named');
      // Every tap and every wait: git_measure.dart's driver, shared with
      // the emulator gate's git group (git_test.dart).
      final app = await GitDriver.of(tester, container);

      // ── The repository of 10,000 files ─────────────────────────────────
      final largeRoot = await app.openProject(_large);
      final writtenMs = writeLargeRepository(largeRoot);
      final made = await app.control.init();
      expect(made.isOk, isTrue, reason: 'init the repository: $made');
      await pumpUntil(
        tester,
        () => app.repo.kind == GitRepoKind.repository,
        what: 'the project to become a repository',
        timeout: const Duration(minutes: 3),
      );
      await app.openPanel();
      await app.statusWhere(
        (status) => status.untracked.isNotEmpty,
        what: 'the panel to list what is new',
        timeout: const Duration(minutes: 5),
      );
      expect(
        app.repo.status!.changeCount,
        largeFileCount,
        reason: 'every file is listed as new',
      );
      final untracked = await measureStatuses(
        tester,
        container,
        'untracked',
        files: largeFileCount,
        samples: 5,
      );
      _statuses('untracked', untracked);
      // The memory with the panel open on ten thousand changes.
      await tester.pump(const Duration(seconds: 3));
      final before = await memory('git-untracked');

      // ── The commit, with Flutter's frames ──────────────────────────────
      final commitWatch = Stopwatch()..start();
      final (_, commitFrames) = await measureFrames(
        tester,
        binding,
        () => app.commitEverything('Ten thousand files'),
      );
      final commitMs = commitWatch.elapsedMilliseconds;
      _figure('commit_ms', commitMs);
      _frames('commit', commitFrames);
      expect(app.repo.status!.branch.unborn, isFalse, reason: 'it committed');

      // ── The status the panel refreshes, with Flutter's frames ──────────
      final (clean, statusFrames) = await measureFrames(
        tester,
        binding,
        () =>
            measureStatuses(tester, container, 'clean', files: largeFileCount),
      );
      _statuses('clean', clean);
      _frames('status', statusFrames);

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
      _statuses('changed', changed);
      expect(app.repo.status!.changeCount, filesPerFolder);
      // Put them back, so the clone below serves a clean repository.
      for (var file = 0; file < filesPerFolder; file++) {
        final name = 'd0000/f${file.toString().padLeft(2, '0')}.txt';
        File('$largeRoot/$name').writeAsStringSync('folder 0, file $file\n');
      }
      await app.control.refresh();
      await app.statusWhere(
        (status) => status.clean,
        what: 'the repository to be clean again',
        timeout: const Duration(minutes: 5),
      );

      // ── The clone of those 10,000 files, with a token ──────────────────
      final token = freshToken();
      final server = await GitRemoteServer.start(
        runtimeService,
        user: serverUser,
        token: token,
        seedRepository: largeRoot,
      );
      _figure('server_start_ms', server.startMs);
      final cloneRoot = '${app.projectsRoot}/$_clone';
      var credentialAsks = 0;
      var cloneMs = 0;
      late UiFrames cloneFrames;
      late MemorySample after;
      try {
        await app.closePanel();
        await app.tap('workbench_home');
        await app.waitFor('clone_repository');
        await app.tap('clone_repository');
        await app.waitFor('clone_dialog');
        await app.type('clone_url', server.url);
        await app.type('clone_name', _clone);
        final cloneWatch = Stopwatch()..start();
        await app.tap('clone_confirm');
        final (_, frames) = await measureFrames(tester, binding, () async {
          // The credential dialog, answered with the run's token and
          // *Remember on this device* left on.
          await app.waitFor(
            'git_credential_dialog',
            timeout: const Duration(minutes: 2),
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
          await pumpUntil(
            tester,
            () => Directory('$cloneRoot/.git').existsSync(),
            what: 'the clone to land',
            timeout: const Duration(minutes: 8),
          );
          await pumpUntil(
            tester,
            () => app.repo.project == _clone,
            what: 'the clone to open as the workspace',
            timeout: const Duration(minutes: 3),
          );
        });
        cloneFrames = frames;
        cloneMs = cloneWatch.elapsedMilliseconds;
        expect(credentialAsks, 1, reason: 'the token was asked for once');
        // What came down is the repository, every file of it.
        expect(
          Directory('$cloneRoot/d0000').listSync().length,
          filesPerFolder,
          reason: 'the first folder was checked out whole',
        );
        expect(File('$cloneRoot/d0099/f99.txt').existsSync(), isTrue);
        await app.statusWhere(
          (status) => status.clean,
          what: 'the clone to be a clean repository',
          timeout: const Duration(minutes: 5),
        );
        _figure('clone_ms', cloneMs);
        _figure('clone_files', largeFileCount);
        _frames('clone', cloneFrames);
        await tester.pump(const Duration(seconds: 3));
        after = await memory('git-clone');
      } finally {
        await server.stop();
      }
      gate.done();

      final frozen =
          commitFrames.frozen + statusFrames.frozen + cloneFrames.frozen;
      _figure('build', buildMode);
      _figure('files', largeFileCount);
      _figure('written_ms', writtenMs);
      _figure('frozen_frames', frozen);
      _figure('memory_before_mb', before.megabytes(before.totalKb));
      _figure('memory_after_mb', after.megabytes(after.totalKb));
      _figure(
        'memory_delta_mb',
        after.megabytes(after.totalKb - before.totalKb),
      );
      _line(
        'memory before_mb=${before.megabytes(before.totalKb)} '
        'after_mb=${after.megabytes(after.totalKb)} '
        'renderers=${after.renderers} build=$buildMode',
      );
      await printReport('CODEFORGE_GIT_JSON', {
        'test': 'phone_git',
        'build': buildMode,
        'files': largeFileCount,
        'writtenMs': writtenMs,
        'budgets': {
          'statusP95Ms': statusBudgetMs,
          'slowFrameMs': slowFrameMs,
          'slowFramePct': slowFrameBudgetPct,
          'frozenFrameMs': frozenFrameMs,
        },
        'status': {
          'untracked': untracked.toJson(),
          'clean': clean.toJson(),
          'changed': changed.toJson(),
        },
        'commit': {'ms': commitMs, 'frames': commitFrames.toJson()},
        'statusFrames': statusFrames.toJson(),
        'clone': {
          'ms': cloneMs,
          'serverStartMs': server.startMs,
          'credentialAsks': credentialAsks,
          'frames': cloneFrames.toJson(),
        },
        'memory': {
          'before': before.toJson(),
          'after': after.toJson(),
          'deltaMb': after.megabytes(after.totalKb - before.totalKb),
        },
      });
      // The budgets themselves are the judge's (gate_results.py
      // --require); a frame the user would call a freeze fails here too.
      expect(frozen, 0, reason: 'no frozen frame while git worked');
    },
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  phoneGitTests();
}
