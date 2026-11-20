/// The terminal and a folder's copy on a phone (Phase 5 W6, gate G6).
///
/// Firebase Test Lab runs these with no computer attached, in the same
/// entrypoint as the session store's timings and search
/// (sync_modes_test.dart calls [phoneTerminalTests]), on its arm64 phone.
/// The gate's requests (folder_gate.dart) are answered there by the
/// instrumentation (androidTest's syncmodes/GateAnswers.java): memory
/// through its shell, the gate folder written by the shell user, and
/// Android's folder picker through the accessibility tree.
///
/// 1. **The terminal** (terminal_measure.dart): echo, the 10 MiB flood with
///    Flutter's frames and the page's, and the memory, with xterm.js's DOM
///    renderer, then WebGL, then the DOM's again. The figures go to the
///    device log as `RUNTIME_GATE` lines, which tool/ci/gate_results.py
///    holds to ADR-0006's budgets (`--require`), and as a
///    CODEFORGE_TERMINAL_JSON document.
/// 2. **A folder's copy** (ADR-0013; W4's caps, measured on a phone): the
///    gate folder of 1,006 files in Documents, picked through Android's
///    picker and run through its copy three times, as the emulator gate's
///    run group does: the first copy takes every file, the second none, the
///    third the one file the shell changed. The times are recorded, never
///    judged.
///
/// The Test Lab job's build is a debug build (the store's and search's
/// figures say so too); the reports say it.
library;

import 'dart:async';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/run/run_controller.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/application/terminal/terminal_controller.dart';
import 'package:codeforge/application/terminal/terminal_providers.dart';
import 'package:codeforge/application/terminal/terminal_view.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 exports Override from misc.dart, not the main library.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_fixture.dart';
import 'folder_gate.dart';
import 'smoke_test.dart' show pumpRealApp, pumpUntil;
import 'terminal_measure.dart';

/// The prompt CodeForge's rc file gives bash in the demo project.
const String _prompt = r'demo $';

/// What the folder's run does, as in the run group (run_test.dart).
const String _folderRun = '''
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
const hello = readFileSync('hello.txt', 'utf8').trim();
const many = readdirSync('many').length;
mkdirSync('out', { recursive: true });
writeFileSync('out/result.txt', `\${hello} / \${many} files\\n`);
console.log(`gate copy: \${hello} / \${many} files`);
''';

/// A figure for tool/ci/gate_results.py, straight to the device log.
void _figure(String key, Object value) =>
    Zone.root.print('RUNTIME_GATE $key=$value');

/// Starts the real app on the demo project and waits for the runtime.
Future<ProviderContainer> _startOnTheDemo(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  await pumpRealApp(tester, prefs, overrides: overrides);
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
  return container;
}

void phoneTerminalTests() {
  testWidgets(
    'terminal: echo, the flood and memory on a phone (G6)',
    timeout: const Timeout(Duration(minutes: 20)),
    (tester) async {
      final binding = tester.binding as IntegrationTestWidgetsFlutterBinding;
      final container = await _startOnTheDemo(tester);
      final gate = await FolderGate.start();
      final memory = memoryFrom(
        (request) => gate.ask(request, timeout: const Duration(seconds: 90)),
      );
      // The memory before any terminal: the editor open on main.js.
      await openInEditor(tester, container, 'main.js');
      await tester.pump(const Duration(seconds: 3));
      final before = await memory('before');

      container
          .read(shellControllerProvider.notifier)
          .setTerminalStop(TerminalStop.full);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('terminal_new_empty')));
      await pumpUntil(
        tester,
        () {
          final panel = container.read(terminalControllerProvider);
          return (panel.active?.running ?? false) &&
                  panel.viewPhase == TerminalViewPhase.ready ||
              panel.message != null ||
              panel.viewPhase == TerminalViewPhase.failed;
        },
        what: 'a terminal to start',
        timeout: const Duration(minutes: 1),
      );
      final panel = container.read(terminalControllerProvider);
      expect(panel.message, isNull);
      expect(
        panel.viewPhase,
        TerminalViewPhase.ready,
        reason: panel.viewMessage,
      );
      final id = panel.activeId!;
      final view = container.read(terminalViewProvider);
      final service = container.read(terminalServiceProvider);

      Future<void> write(String text) async {
        final written = await service.write(id, typed(text));
        expect(written.isOk, isTrue, reason: '$written');
      }

      Future<void> promptShown(String what) async {
        final watch = Stopwatch()..start();
        TerminalSnapshot? last;
        while (watch.elapsed < const Duration(seconds: 60)) {
          if (await view.snapshot(id) case Ok(:final value)) {
            last = value;
            if (value.cursorY < value.screen.length &&
                value.screen[value.cursorY].contains(_prompt)) {
              return;
            }
          }
          await tester.pump(const Duration(milliseconds: 150));
        }
        fail('Timed out waiting for $what:\n${last?.screen.join('\n')}');
      }

      await promptShown('the prompt');
      final opened = await memory('opened');
      final demo = '${await applicationFilesPath()}/workspaces/demo';
      final measured = await measureTerminal(
        tester: tester,
        binding: binding,
        view: view,
        id: id,
        folder: demo,
        write: write,
        promptShown: promptShown,
        memory: memory,
        before: before,
        opened: opened,
        report: (line) => debugPrint('phone terminal: $line'),
      );
      await container.read(terminalControllerProvider.notifier).close(id);
      await tester.pumpAndSettle();
      gate.done();

      await printReport('CODEFORGE_TERMINAL_JSON', {
        'test': 'phone_terminal',
        'build': kDebugMode ? 'debug' : 'release',
        ...measured.toJson(),
      });
      final echo = measured.shippedEcho;
      final flood = measured.shippedFlood;
      _figure('page_renderer_shipped', shippedRenderer);
      _figure('page_echo_p50_ms', echo.p50Ms);
      _figure('page_echo_p95_ms', echo.p95Ms);
      _figure('page_echo_max_ms', echo.maxMs);
      _figure('page_echo_lost', echo.lost);
      _figure('page_echo_under_budget', echo.underBudget ? 1 : 0);
      _figure(
        'page_flood_whole',
        measured.flood.values.every((f) => f.whole) ? 1 : 0,
      );
      _figure('page_flood_ms', flood.ms);
      _figure('page_flood_mib_s', flood.mibPerSecond);
      _figure('page_flood_ui_frames', flood.ui.frames);
      _figure('page_flood_ui_slow_pct', flood.ui.slowPct);
      _figure('page_flood_ui_frozen', flood.ui.frozen);
      _figure('page_flood_ui_longest_gap_ms', flood.ui.longestGapMs);
      _figure('page_flood_ui_under_budget', flood.ui.underBudget ? 1 : 0);
      _figure('page_flood_page_slow_pct', flood.pageSlowPct);
      _figure('page_memory_before_mb', before.megabytes(before.totalKb));
      _figure('page_memory_delta_mb', measured.deltaMb);
      _figure('page_memory_under_budget', measured.memoryUnderBudget ? 1 : 0);
      _figure('page_webgl', measured.webglRenderer);
      final webgl = measured.flood['webgl'];
      if (webgl != null) {
        _figure('page_webgl_echo_p95_ms', measured.echo['webgl']!.p95Ms);
        _figure('page_webgl_flood_ms', webgl.ms);
        _figure('page_webgl_flood_page_slow_pct', webgl.pageSlowPct);
        _figure('page_webgl_flood_ui_slow_pct', webgl.ui.slowPct);
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(echo.lost, 0);
      for (final run in measured.flood.values) {
        expect(run.whole, isTrue, reason: 'the flood (${run.line()})');
      }
    },
  );

  testWidgets(
    'run: a folder through its copy, on a phone',
    timeout: const Timeout(Duration(minutes: 15)),
    (tester) async {
      final gate = await FolderGate.start();
      expect(
        await gate.ask('fixture', timeout: const Duration(minutes: 3)),
        'done:1000',
      );
      final container = await _startOnTheDemo(
        tester,
        overrides: [
          folderPickerStartProvider.overrideWithValue(gateFolderStartUri),
        ],
      );
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

      final runs = container.read(runControllerProvider.notifier);
      RunRecord record(int sessionId) => container
          .read(runControllerProvider)
          .runs
          .firstWhere((run) => run.sessionId == sessionId);

      Future<RunRecord> folderRun() async {
        final before = container.read(runControllerProvider).latest?.sessionId;
        await runs.runFile('run-gate.mjs');
        await pumpUntil(
          tester,
          () {
            final state = container.read(runControllerProvider);
            return state.message != null ||
                (!state.starting && state.latest?.sessionId != before);
          },
          what: 'the run to start',
          timeout: const Duration(minutes: 5),
        );
        final state = container.read(runControllerProvider);
        expect(state.latest?.sessionId, isNot(before), reason: state.message);
        final id = state.latest!.sessionId;
        await pumpUntil(
          tester,
          () => !record(id).running,
          what: 'run $id to end',
          timeout: const Duration(minutes: 3),
        );
        final done = record(id);
        expect(done.exitCode, 0);
        await container.read(terminalControllerProvider.notifier).close(id);
        await tester.pump();
        return done;
      }

      final figures = <String, Object?>{};
      void copied(String name, RunRecord run) {
        final summary = run.copy!.summary;
        debugPrint(
          'phone copy: $name files=${summary.files} copied=${summary.copied} '
          'unchanged=${summary.unchanged} bytes=${summary.bytes} '
          'ms=${summary.elapsed.inMilliseconds}',
        );
        figures[name] = {
          'files': summary.files,
          'copied': summary.copied,
          'unchanged': summary.unchanged,
          'removed': summary.removed,
          'bytes': summary.bytes,
          'bytesCopied': summary.bytesCopied,
          'ms': summary.elapsed.inMilliseconds,
        };
        _figure('copy_${name}_files', summary.files);
        _figure('copy_${name}_copied', summary.copied);
        _figure('copy_${name}_ms', summary.elapsed.inMilliseconds);
      }

      final first = await folderRun();
      expect(first.copy!.summary.copied, first.copy!.summary.files);
      expect(first.copy!.summary.files, greaterThanOrEqualTo(1006));
      copied('first', first);
      final second = await folderRun();
      expect(second.copy!.summary.copied, 0);
      copied('second', second);
      expect(await gate.ask('put hello.txt changed'), 'done');
      final third = await folderRun();
      expect(third.copy!.summary.copied, 1);
      copied('third', third);
      gate.done();
      await printReport('CODEFORGE_COPY_JSON', {
        'test': 'phone_copy',
        'build': kDebugMode ? 'debug' : 'release',
        ...figures,
      });
    },
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  phoneTerminalTests();
}
