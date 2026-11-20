/// Gate G5, the sessions group's part A (Phase 5 W5): terminal sessions that
/// last, in the real app on the emulator, on the sealed runtime.
///   1. Three sessions: `seven`, which exits with code 7; `heartbeat`, which
///      writes the time to .cf-beats and a line to its terminal every
///      second; and a shell with a job in the background. The foreground
///      service runs, its notification counting the two that run.
///   2. Memory pressure: the gate sends Android's warnings (`am
///      send-trim-memory`, RUNNING_LOW, then RUNNING_CRITICAL). The hidden
///      sessions' views go, the host trims their buffers, and nothing ends:
///      shown again, the heartbeat draws its last lines and goes on.
///   3. Five minutes in the background: the gate presses Home, and brings
///      the app back after five minutes. The heartbeat never stops for more
///      than a few seconds, the service runs throughout, the shown session
///      is drawn again on return, and the shell answers.
///   4. The process dies: the gate kills it as Android's low-memory killer
///      does (kill -9) and records what is left of the sessions' processes;
///      `flutter test` loses the app, which is expected. Part B
///      (sessions_b_test.dart) finds the tombstones.
///
/// The host's half is app/tool/ci/emulator_gate.sh's folder driver
/// (FolderGate: `service`, `trim`, `procs`, `home`, `front`, `die`). The
/// gate reads the SESSIONS_GATE lines.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/application/terminal/terminal_controller.dart';
import 'package:codeforge/application/terminal/terminal_providers.dart';
import 'package:codeforge/application/terminal/terminal_view.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/terminal/terminal_models.dart';
import 'package:codeforge/services/platform/app_directories.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_gate.dart';
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

/// The heartbeat's command line holds this: the gate finds its processes by it.
const String heartbeatMarker = 'cf-heartbeat-5201';

/// The shell's background job: `sleep` for this long.
const String shellJobMarker = '9999.5202';

/// How long the app stays in the background.
const Duration away = Duration(minutes: 5, seconds: 10);

/// The heartbeat: the time in .cf-beats and a line on the terminal, each second.
const String _heartbeat =
    r'rm -f .cf-beats; n=0; while :; do n=$((n + 1)); '
    r'date +%s >> .cf-beats; echo "beat $n"; sleep 1; done';

final RegExp _beatLine = RegExp(r'^beat (\d+)\s*$');

/// A line for the gate: in the test's output and in the device log, which
/// outlives the process this test ends with.
void report(String line) {
  Zone.root.print('SESSIONS_GATE $line');
  debugPrint('SESSIONS_GATE $line');
}

/// The highest `beat N` on [screen], or 0.
int lastBeat(TerminalSnapshot screen) {
  var last = 0;
  for (final line in [...screen.scrollback, ...screen.screen]) {
    final match = _beatLine.firstMatch(line);
    if (match != null) {
      final n = int.parse(match.group(1)!);
      if (n > last) {
        last = n;
      }
    }
  }
  return last;
}

/// The times the heartbeat wrote, in seconds since the epoch.
List<int> beatsIn(File file) {
  if (!file.existsSync()) {
    return const [];
  }
  return [
    for (final line in file.readAsLinesSync()) ?int.tryParse(line.trim()),
  ];
}

bool _away() {
  final state = WidgetsBinding.instance.lifecycleState;
  return state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
}

/// Waits with plain timers, not frames: in the background, Flutter draws
/// nothing, and a pump would wait for the app to come back.
Future<void> waitPlain(
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('Timed out after ${timeout.inSeconds} s waiting for $what.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'sessions A: the service, memory pressure, five minutes away, then the '
    'process dies',
    (tester) async {
      final gate = await FolderGate.start();
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await pumpRealApp(tester, prefs);
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

      container
          .read(shellControllerProvider.notifier)
          .setTerminalStop(TerminalStop.full);
      await tester.pumpAndSettle();
      final terminals = container.read(terminalControllerProvider.notifier);
      final view = container.read(terminalViewProvider);
      final service = container.read(terminalServiceProvider);
      TerminalPanelState panel() => container.read(terminalControllerProvider);

      Future<TerminalSnapshot> screenOf(
        int id,
        bool Function(TerminalSnapshot screen) ok, {
        required String what,
        Duration timeout = const Duration(seconds: 30),
      }) async {
        final watch = Stopwatch()..start();
        TerminalSnapshot? last;
        while (watch.elapsed < timeout) {
          final snapshot = await view.snapshot(id, scrollback: 200);
          if (snapshot case Ok(:final value)) {
            last = value;
            if (ok(value)) {
              return value;
            }
          }
          await tester.pump(const Duration(milliseconds: 200));
        }
        fail(
          'Timed out after ${timeout.inSeconds} s waiting for $what. The '
          'screen:\n${last?.screen.join('\n')}',
        );
      }

      Future<bool> hasView(int id) async => (await view.snapshot(id)).isOk;

      Future<int> run(TerminalSpec spec) async {
        final started = await terminals.run(spec);
        final id = switch (started) {
          Ok(:final value) => value,
          Err(:final failure) => fail('${spec.label}: ${failure.message}'),
        };
        await pumpUntil(
          tester,
          () =>
              panel().activeId == id &&
              panel().viewPhase == TerminalViewPhase.ready,
          what: '${spec.label} to show',
        );
        return id;
      }

      // ── 1. Three sessions; the service runs ──────────────────────────────
      final seven = await run(
        const TerminalSpec(
          project: demoProjectFolder,
          program: 'bash',
          arguments: ['-c', 'echo seven-done; exit 7'],
          label: 'seven',
        ),
      );
      await pumpUntil(
        tester,
        () => panel().tabs.any(
          (tab) => tab.sessionId == seven && tab.exitCode == 7,
        ),
        what: 'seven to exit with code 7',
      );
      final heartbeat = await run(
        const TerminalSpec(
          project: demoProjectFolder,
          program: 'bash',
          arguments: ['-c', _heartbeat, heartbeatMarker],
          label: 'heartbeat',
        ),
      );
      final firstBeat = await screenOf(
        heartbeat,
        (screen) => lastBeat(screen) >= 2,
        what: 'the heartbeat to beat',
      );
      await terminals.newSession();
      await pumpUntil(
        tester,
        () =>
            panel().active?.label == 'Terminal 1' &&
            (panel().active?.running ?? false) &&
            panel().viewPhase == TerminalViewPhase.ready,
        what: 'the shell to start',
      );
      final shell = panel().activeId!;
      Future<void> type(int id, String text) async {
        final written = await service.write(
          id,
          Uint8List.fromList(utf8.encode(text)),
        );
        expect(written.isOk, isTrue, reason: '$written');
      }

      bool promptAtCursor(TerminalSnapshot screen) =>
          screen.cursorY < screen.screen.length &&
          screen.screen[screen.cursorY].contains(r'demo $');
      await screenOf(shell, promptAtCursor, what: 'the prompt');
      await type(shell, 'sleep $shellJobMarker &\r');
      await screenOf(
        shell,
        (screen) =>
            screen.screen.any((line) => line.startsWith('[1] ')) &&
            promptAtCursor(screen),
        what: 'the job to start',
      );
      final started = await gate.ask('service');
      report('service_started $started');
      expect(started, startsWith('fg:1,'));
      expect(started, contains('title:2-terminal-sessions-running'));
      report(
        'sessions seven=$seven heartbeat=$heartbeat shell=$shell '
        'first_beat=${lastBeat(firstBeat)}',
      );

      // ── 2. Memory pressure: views go, buffers trim, nothing ends ─────────
      expect(panel().activeId, shell);
      expect(await hasView(heartbeat), isTrue);
      final low = await gate.ask('trim RUNNING_LOW');
      expect(low, startsWith('sent'), reason: low);
      final releasing = Stopwatch()..start();
      while (await hasView(heartbeat)) {
        if (releasing.elapsed > const Duration(seconds: 20)) {
          fail('The hidden views stayed after RUNNING_LOW.');
        }
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(await hasView(seven), isFalse, reason: 'a hidden view stayed');
      expect(await hasView(shell), isTrue, reason: 'the shown view went');
      await tester.pump(const Duration(seconds: 1));
      final critical = await gate.ask('trim RUNNING_CRITICAL');
      report(
        'pressure low=$low critical=$critical '
        'released_ms=${releasing.elapsedMilliseconds}',
      );
      expect(critical, 'sent,trimmed:2', reason: 'two sessions had no view');
      terminals.activate(heartbeat);
      final redrawn = await screenOf(
        heartbeat,
        (screen) => lastBeat(screen) > 0,
        what: 'the heartbeat drawn again',
      );
      final beatAfterPressure = lastBeat(redrawn);
      await screenOf(
        heartbeat,
        (screen) => lastBeat(screen) > beatAfterPressure,
        what: 'the heartbeat to beat on after the pressure',
      );
      expect(
        panel().tabs.where((tab) => tab.running).map((tab) => tab.sessionId),
        unorderedEquals([heartbeat, shell]),
        reason: 'nothing ends for memory',
      );
      report('pressure redrawn_beat=$beatAfterPressure running=2');

      // ── 3. Five minutes in the background ────────────────────────────────
      final beats = File(
        '${await applicationFilesPath()}/workspaces/$demoProjectFolder/.cf-beats',
      );
      await gate.home();
      await waitPlain(_away, what: 'the app to go to the background');
      final left = DateTime.now();
      final leftSeconds = left.millisecondsSinceEpoch ~/ 1000;
      var looked = false;
      while (DateTime.now().difference(left) < away) {
        await Future<void>.delayed(const Duration(seconds: 30));
        final elapsed = DateTime.now().difference(left).inSeconds;
        debugPrint(
          'sessions gate: away $elapsed s, beats ${beatsIn(beats).length}',
        );
        if (!looked && elapsed >= 60) {
          looked = true;
          final awayService = await gate.ask('service');
          final awayProcesses = await gate.ask('procs $heartbeatMarker');
          report('away service=$awayService processes=$awayProcesses');
          expect(
            awayService,
            startsWith('fg:1,'),
            reason: 'the service stopped in the background',
          );
        }
      }
      await gate.front();
      await waitPlain(
        () =>
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
        what: 'the app to come back',
      );
      final backSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final during = [
        for (final seconds in beatsIn(beats))
          if (seconds >= leftSeconds && seconds <= backSeconds) seconds,
      ];
      var gap = during.isEmpty ? backSeconds - leftSeconds : 0;
      if (during.isNotEmpty) {
        gap = during.first - leftSeconds;
        for (var i = 1; i < during.length; i++) {
          if (during[i] - during[i - 1] > gap) {
            gap = during[i] - during[i - 1];
          }
        }
        if (backSeconds - during.last > gap) {
          gap = backSeconds - during.last;
        }
      }
      final awaySeconds = backSeconds - leftSeconds;
      report(
        'background seconds=$awaySeconds beats=${during.length} '
        'longest_gap_s=$gap',
      );
      expect(awaySeconds, greaterThanOrEqualTo(300));
      expect(
        during.length,
        greaterThanOrEqualTo(awaySeconds * 8 ~/ 10),
        reason: 'the heartbeat slowed or stopped in the background',
      );
      expect(gap, lessThanOrEqualTo(10), reason: 'the heartbeat stopped');

      // Back: the shown session drawn again from the host's buffer, and on.
      await pumpUntil(
        tester,
        () => panel().viewPhase == TerminalViewPhase.ready,
        what: 'the terminal page after the return',
      );
      final back = await screenOf(
        heartbeat,
        (screen) => lastBeat(screen) > beatAfterPressure + 250,
        what: 'the heartbeat drawn again after the return',
      );
      terminals.activate(shell);
      await screenOf(shell, promptAtCursor, what: 'the shell after the return');
      await type(
        shell,
        r'echo cf-alive-$((6 * 7))'
        '\r',
      );
      await screenOf(
        shell,
        (screen) => screen.screen.any((line) => line.trim() == 'cf-alive-42'),
        what: 'the shell to answer after five minutes',
      );
      final processes = await gate.ask('procs $shellJobMarker');
      report('return beat=${lastBeat(back)} shell=answers job=$processes');
      expect(processes, startsWith('count:1,'), reason: processes);

      // ── 4. The process dies ──────────────────────────────────────────────
      report('part_a=ok');
      gate.tell('die');
      await Future<void>.delayed(const Duration(seconds: 90));
      fail('The gate did not end the app.');
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
