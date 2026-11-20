/// Gate G4, the run group (Phase 5 W4): Run in the real app on the emulator,
/// on the sealed runtime.
///   1. Files and an npm script give their exact output and exit code: the
///      demo project's main.js (node) and app.py (python), a shell script
///      that exits 3, and the demo's `npm run start`.
///   2. Stop ends a run with everything it started: a node program and the
///      `sleep` it spawned are gone after Stop, and no process is left.
///   3. The native-addon limitation: `npm install` of a local package that
///      builds with node-gyp fails for want of a compiler, and its terminal
///      shows the banner.
///   4. The E2E scenario, part 1: a new file, a program typed through the
///      editor page, saved and run, its output; then an edit, run again (Run
///      saves first), the new output.
///   5. A folder runs through its copy (ADR-0013): the gate folder with its
///      1,000-file many/, picked in Android's picker (the host's
///      folder_driver answers it). The first copy, the second (nothing to
///      copy) and a third after the host changed a file are timed; the file
///      the run wrote is exported to the folder and checked on disk.
/// The gate reads the RUN_GATE lines (app/tool/ci/emulator_gate.sh).
library;

import 'dart:convert';
import 'dart:io';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/file_operations.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/run/run_controller.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/application/terminal/terminal_controller.dart';
import 'package:codeforge/application/terminal/terminal_providers.dart';
import 'package:codeforge/application/terminal/terminal_view.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/terminal/native_addons.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/storage/drift_session_store.dart'
    show appDatabaseFileName;
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_fixture.dart';
import 'folder_gate.dart';
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

void _report(String line) => debugPrint('RUN_GATE $line');

/// The demo's main.js, run.
const List<String> _helloLines = [
  'Hello from JavaScript!',
  'Hello from Python!',
  'Hello from Dart!',
];

/// A node program that spawns a sleep no other process runs, and stays.
const String _forever = '''
import { spawn } from 'node:child_process';
spawn('sleep', ['311.7'], { stdio: 'ignore' });
console.log('forever started');
setInterval(() => {}, 1000);
''';

/// A local package that builds a native addon, and the script that builds
/// it with npm's own node-gyp: npm 12 no longer runs a dependency's install
/// script unasked (phase gate 44697552696: `npm install` of it printed no
/// gyp line at all). node-gyp finds the runtime's node headers through
/// npm_config_nodedir, so the build reaches the missing compiler without
/// the network. The script says where node-gyp is, for the evidence.
const Map<String, String> _addon = {
  'addon/package.json':
      '{"name": "cf-gate-addon", "version": "1.0.0", "gypfile": true}\n',
  'addon/binding.gyp':
      '{"targets": [{"target_name": "addon", "sources": ["addon.c"]}]}\n',
  'addon/addon.c': 'int answer(void) { return 42; }\n',
  'gate-native.sh':
      'if [ -d "\$PREFIX/include/node" ]; then\n'
      '  export npm_config_nodedir="\$PREFIX"\n'
      'fi\n'
      'gyp="\$PREFIX/lib/node_modules/npm/node_modules/node-gyp/bin/'
      'node-gyp.js"\n'
      'echo "node-gyp: \$gyp"\n'
      'cd addon && node "\$gyp" rebuild\n',
};

/// What the folder's run does: reads the folder, writes a file, says so.
const String _folderRun = '''
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
const hello = readFileSync('hello.txt', 'utf8').trim();
const many = readdirSync('many').length;
mkdirSync('out', { recursive: true });
writeFileSync('out/result.txt', `\${hello} / \${many} files\\n`);
console.log(`gate copy: \${hello} / \${many} files`);
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'run: files and npm, Stop, native addons, E2E part 1, a folder',
    timeout: const Timeout(Duration(minutes: 25)),
    (tester) async {
      final gate = await FolderGate.start();
      // A clean slate: no session database, no project from an earlier
      // attempt.
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
      await pumpRealApp(
        tester,
        prefs,
        overrides: [
          folderPickerStartProvider.overrideWithValue(gateFolderStartUri),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CodeForgeApp)),
        listen: false,
      );
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
      final demo = '${projects.path}/$demoProjectFolder';

      final runs = container.read(runControllerProvider.notifier);
      final view = container.read(terminalViewProvider);

      RunRecord record(int sessionId) => container
          .read(runControllerProvider)
          .runs
          .firstWhere((run) => run.sessionId == sessionId);

      /// Starts a run with [start] and waits until it has started.
      Future<int> started(Future<void> Function() start) async {
        final before = container.read(runControllerProvider).latest?.sessionId;
        await start();
        await pumpUntil(
          tester,
          () {
            final state = container.read(runControllerProvider);
            return state.message != null ||
                (!state.starting && state.latest?.sessionId != before);
          },
          what: 'the run to start',
          timeout: const Duration(minutes: 3),
        );
        final state = container.read(runControllerProvider);
        expect(state.latest?.sessionId, isNot(before), reason: state.message);
        return state.latest!.sessionId;
      }

      /// Closes run [sessionId]'s ended terminal: eight at most stay open.
      Future<void> close(int sessionId) async {
        await container
            .read(terminalControllerProvider.notifier)
            .close(sessionId);
        await tester.pump();
      }

      /// The run's terminal: its scrollback and screen, without the blank
      /// lines at the ends.
      Future<List<String>> outputOf(int sessionId) async {
        final TerminalSnapshot value;
        switch (await view.snapshot(sessionId, scrollback: 500)) {
          case Ok(value: final snapshot):
            value = snapshot;
          case Err(:final failure):
            fail('No snapshot of run $sessionId: ${failure.message}');
        }
        final lines = [
          for (final line in [...value.scrollback, ...value.screen])
            line.trimRight(),
        ];
        while (lines.isNotEmpty && lines.first.isEmpty) {
          lines.removeAt(0);
        }
        while (lines.isNotEmpty && lines.last.isEmpty) {
          lines.removeLast();
        }
        return lines;
      }

      /// Waits until run [sessionId] has ended and its output holds
      /// [expected] (or anything, when null); its record and its lines.
      Future<(RunRecord, List<String>)> finished(
        int sessionId, {
        List<String>? expected,
        Duration timeout = const Duration(minutes: 2),
      }) async {
        await pumpUntil(
          tester,
          () => !record(sessionId).running,
          what: 'run $sessionId to end',
          timeout: timeout,
        );
        var lines = await outputOf(sessionId);
        final watch = Stopwatch()..start();
        while (expected != null &&
            !expected.every(lines.contains) &&
            watch.elapsed < const Duration(seconds: 15)) {
          await tester.pump(const Duration(milliseconds: 200));
          lines = await outputOf(sessionId);
        }
        return (record(sessionId), lines);
      }

      void writeDemo(String path, String text) {
        File('$demo/$path')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);
      }

      // ── 1. Files and an npm script: exact output, exit codes ────────────
      final js = await started(() => runs.runFile('main.js'));
      final (jsRun, jsLines) = await finished(js, expected: _helloLines);
      expect(jsLines, _helloLines);
      expect(jsRun.exitCode, 0);
      expect(jsRun.command.program, 'node');
      _report(
        'file=main.js program=node exit=${jsRun.exitCode} '
        'lines=${jsLines.length}',
      );
      await close(js);

      final py = await started(() => runs.runFile('app.py'));
      final (pyRun, pyLines) = await finished(
        py,
        expected: const ['Forge at 1250°C'],
      );
      expect(pyLines, ['Forge at 1250°C']);
      expect(pyRun.exitCode, 0);
      _report('file=app.py program=python exit=${pyRun.exitCode}');
      await close(py);

      writeDemo('gate-shell.sh', 'echo "shell \$((6 * 7))"\nexit 3\n');
      final sh = await started(() => runs.runFile('gate-shell.sh'));
      final (shRun, shLines) = await finished(sh, expected: const ['shell 42']);
      expect(shLines, ['shell 42']);
      expect(shRun.exitCode, 3);
      expect(shRun.status, 'Exit 3');
      _report('file=gate-shell.sh program=bash exit=${shRun.exitCode}');
      await close(sh);

      final choices = await runs.projectRuns();
      final start = choices.firstWhere((run) => run.title == 'npm run start');
      final npm = await started(() => runs.runCommand(start));
      final (npmRun, npmLines) = await finished(
        npm,
        expected: _helloLines,
        timeout: const Duration(minutes: 3),
      );
      // The script's own output, exactly; npm's banner (`> name@version
      // script`, which npm 12 leaves out here) and its notices are npm's.
      expect([
        for (final line in npmLines)
          if (!line.startsWith('> ') &&
              !line.startsWith('npm notice') &&
              !line.startsWith('npm warn'))
            line,
      ], _helloLines);
      expect(npmRun.exitCode, 0);
      _report(
        'npm=start exit=${npmRun.exitCode} lines=${npmLines.length} '
        'banner=${npmLines.any((line) => line.startsWith('> '))}',
      );
      await close(npm);

      // ── 2. Stop leaves no process ────────────────────────────────────────
      Future<int?> processes(String pattern) async {
        final found = await container
            .read(runtimeControllerProvider.notifier)
            .exec('pgrep', ['-f', pattern]);
        final value = (found as Ok<ExecResult>).value;
        // pgrep: 0 when it found any, 1 when none.
        return value.exitCode == 0
            ? const LineSplitter().convert(value.stdout.trim()).length
            : value.exitCode == 1
            ? 0
            : null;
      }

      writeDemo('gate-forever.js', _forever);
      final forever = await started(() => runs.runFile('gate-forever.js'));
      final watch = Stopwatch()..start();
      while (!(await outputOf(forever)).contains('forever started')) {
        expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
        await tester.pump(const Duration(milliseconds: 200));
      }
      // The brackets keep pgrep's own launcher, whose arguments hold the
      // pattern, from matching it.
      expect(await processes('[s]leep 311.7'), 1);
      final stopping = Stopwatch()..start();
      await runs.stop(forever);
      final (stopped, _) = await finished(
        forever,
        timeout: const Duration(seconds: 30),
      );
      final stopMs = stopping.elapsedMilliseconds;
      int? left;
      final settle = Stopwatch()..start();
      do {
        left =
            (await processes('[s]leep 311.7'))! +
            (await processes('[g]ate-forever.js'))!;
        if (left > 0) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      } while (left > 0 && settle.elapsed < const Duration(seconds: 10));
      expect(left, 0, reason: 'a process outlived Stop');
      _report('stop status="${stopped.status}" ms=$stopMs left=$left');
      await close(forever);

      // ── 3. A native addon that needs a compiler ──────────────────────────
      for (final MapEntry(:key, :value) in _addon.entries) {
        writeDemo(key, value);
      }
      final native = await started(() => runs.runFile('gate-native.sh'));
      final (nativeRun, nativeLines) = await finished(
        native,
        timeout: const Duration(minutes: 4),
      );
      await tester.pumpAndSettle();
      // What the build said, whatever comes next: the evidence.
      final tail = nativeLines.length > 12
          ? nativeLines.sublist(nativeLines.length - 12)
          : nativeLines;
      _report('native_output ${tail.map((line) => line.trim()).join(' | ')}');
      final kind = container
          .read(terminalControllerProvider)
          .tabs
          .firstWhere((tab) => tab.sessionId == native)
          .nativeAddon;
      expect(kind, NativeAddonKind.npm);
      expect(
        find.byKey(const ValueKey('terminal_native_addon')),
        findsOneWidget,
      );
      expect(nativeRun.exitCode, isNot(0));
      final gyp = nativeLines.where((line) => line.contains('gyp ERR!'));
      _report(
        'native kind=${kind?.name} exit=${nativeRun.exitCode} '
        'first="${gyp.isEmpty ? '' : gyp.first.trim()}"',
      );
      await close(native);

      // ── 4. The E2E scenario, part 1 ──────────────────────────────────────
      final host = container.read(editorHostProvider);
      expect(
        (await container.read(fileOperationsProvider).createFile('e2e.js'))
            .isOk,
        isTrue,
      );
      await pumpUntil(
        tester,
        () {
          final documents = container.read(documentControllerProvider);
          return documents.activePath == 'e2e.js' &&
              host.status.phase == EditorHostPhase.ready &&
              host.textOf(documents.documents['e2e.js']!.docId) == '';
        },
        what: 'the new file to open in the editor',
        timeout: const Duration(seconds: 60),
      );
      final docId = container
          .read(documentControllerProvider)
          .documents['e2e.js']!
          .docId;
      const first = "console.log('e2e one');\n";
      expect((await host.insert(first)).isOk, isTrue);
      await pumpUntil(
        tester,
        () => host.textOf(docId) == first,
        what: 'the typed program to reach the app',
      );
      expect(
        (await container
                .read(documentControllerProvider.notifier)
                .save('e2e.js'))
            .isOk,
        isTrue,
      );
      expect(File('$demo/e2e.js').readAsStringSync(), first);
      final one = await started(() => runs.runFile('e2e.js'));
      final (oneRun, oneLines) = await finished(one, expected: ['e2e one']);
      expect(oneLines, ['e2e one']);
      expect(oneRun.exitCode, 0);
      await close(one);

      const second = "console.log('e2e two');\n";
      expect((await host.insert(second)).isOk, isTrue);
      await pumpUntil(
        tester,
        () => host.textOf(docId) == first + second,
        what: 'the edit to reach the app',
      );
      expect(
        container.read(documentControllerProvider).documents['e2e.js']!.dirty,
        isTrue,
      );
      // Run saves it first (the setting is on by default).
      final two = await started(() => runs.runFile('e2e.js'));
      final (twoRun, twoLines) = await finished(
        two,
        expected: ['e2e one', 'e2e two'],
      );
      expect(twoLines, ['e2e one', 'e2e two']);
      expect(twoRun.exitCode, 0);
      expect(File('$demo/e2e.js').readAsStringSync(), first + second);
      _report(
        'e2e part1=ok first="${oneLines.join('|')}" '
        'then="${twoLines.join('|')}"',
      );
      await close(two);

      // ── 5. A folder runs through its copy ────────────────────────────────
      await tester.tap(find.byKey(const ValueKey('workbench_home')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('open_folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open_folder')));
      await tester.pump();
      expect(
        await gate.ask(
          'pick $gateFolderName',
          timeout: const Duration(seconds: 240),
        ),
        'picked',
      );
      await pumpUntil(
        tester,
        () =>
            container.read(currentWorkspaceProvider) is FolderLocation &&
            find.byKey(const ValueKey('terminal_toggle')).evaluate().isNotEmpty,
        what: 'the picked folder to open in the workbench',
        timeout: const Duration(seconds: 60),
      );
      await tester.pumpAndSettle();
      final written = await container
          .read(fileServiceProvider)
          .writeText('run-gate.mjs', _folderRun, mode: WriteMode.createNew);
      expect(written.isOk, isTrue, reason: '$written');

      Future<(RunRecord, List<String>)> folderRun(String expected) async {
        final id = await started(() => runs.runFile('run-gate.mjs'));
        final done = await finished(id, expected: [expected]);
        await close(id);
        return done;
      }

      void reportCopy(String name, RunRecord run) {
        final summary = run.copy!.summary;
        _report(
          'copy_$name files=${summary.files} copied=${summary.copied} '
          'unchanged=${summary.unchanged} removed=${summary.removed} '
          'bytes=${summary.bytes} copied_bytes=${summary.bytesCopied} '
          'skipped=${summary.skipped} left_out=${summary.leftOut} '
          'ms=${summary.elapsed.inMilliseconds}',
        );
      }

      const firstLine = 'gate copy: Hello from the gate / 1000 files';
      final (firstRun, firstLines) = await folderRun(firstLine);
      expect(firstLines, [firstLine]);
      expect(firstRun.exitCode, 0);
      final firstCopy = firstRun.copy!.summary;
      expect(firstCopy.copied, firstCopy.files);
      expect(firstCopy.files, greaterThanOrEqualTo(1006));
      expect(firstCopy.leftOut, 0);
      reportCopy('first', firstRun);

      final (secondRun, secondLines) = await folderRun(firstLine);
      expect(secondLines, [firstLine]);
      final secondCopy = secondRun.copy!.summary;
      expect(secondCopy.copied, 0, reason: 'nothing changed in the folder');
      expect(secondCopy.unchanged, firstCopy.files);
      reportCopy('second', secondRun);

      await gate.ask('put hello.txt changed');
      const thirdLine = 'gate copy: changed / 1000 files';
      final (thirdRun, thirdLines) = await folderRun(thirdLine);
      expect(thirdLines, [thirdLine]);
      final thirdCopy = thirdRun.copy!.summary;
      expect(thirdCopy.copied, 1, reason: 'hello.txt changed');
      reportCopy('third', thirdRun);

      // What the run wrote is in the copy only, until it is exported.
      expect(await gate.ask('disk out/result.txt'), 'absent');
      final paths = switch (await runs.changes(thirdRun)) {
        Ok(:final value) => [for (final change in value.changes) change.path],
        Err(:final failure) => fail('No changes: ${failure.message}'),
      };
      expect(paths, contains('out/result.txt'));
      final exported = switch (await runs.export(thirdRun, [
        'out/result.txt',
      ])) {
        Ok(:final value) => value,
        Err(:final failure) => fail('Not exported: ${failure.message}'),
      };
      expect(exported.exported, 1, reason: '${exported.failures}');
      expect(
        await gate.ask('disk out/result.txt'),
        sha256.convert(utf8.encode('changed / 1000 files\n')).toString(),
      );
      _report('export files=1 changes=${paths.length} checked_on_disk=ok');
      await tester.pumpAndSettle();
    },
  );
}
