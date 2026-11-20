/// Gate G5, the sessions group's part B (Phase 5 W5): the next start after
/// the app's process died. Part A (sessions_a_test.dart) left three
/// sessions, two running and one exited with code 7; the gate then killed
/// the process as Android's low-memory killer does. Here:
///   * each session is a tab again, its tombstone: the two that ran "ended
///     by the system", `seven` "exited with code 7"; the last one shows,
///     with its banner, and no service runs for tombstones;
///   * a new session takes an id above theirs and answers; the foreground
///     service starts with it ("1 terminal session running") and stops
///     after it ends;
///   * a tombstone closed is forgotten by the host;
///   * one more session is left running with a job, for `flutter test`'s
///     force-stop at the end, after which the gate looks for its processes.
///
/// The host's half is app/tool/ci/emulator_gate.sh's folder driver
/// (FolderGate: `service`, `procs`). The gate reads the SESSIONS_GATE lines.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/application/terminal/terminal_controller.dart';
import 'package:codeforge/application/terminal/terminal_providers.dart';
import 'package:codeforge/application/terminal/terminal_view.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_gate.dart';
import 'sessions_a_test.dart' show report;
import 'smoke_test.dart' show pumpRealApp, pumpUntil;

/// The job part B leaves running for the force-stop: `sleep` for this long.
const String forceStopMarker = '9999.5203';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sessions B: tombstones after the process died', (tester) async {
    final gate = await FolderGate.start();
    // Part A's settings: the welcome is gone, and the workbench may come
    // back by itself.
    final prefs = await SharedPreferences.getInstance();
    await pumpRealApp(tester, prefs);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final demo = find.byKey(const ValueKey('explore_demo'));
    if (demo.evaluate().isNotEmpty) {
      await tester.ensureVisible(demo);
      await tester.pumpAndSettle();
      await tester.tap(demo);
      await tester.pump();
    }
    await pumpUntil(
      tester,
      () {
        final status = container.read(runtimeControllerProvider);
        return (status.usable && !status.auditing) ||
            status.state == RuntimeState.failed ||
            status.state == RuntimeState.unavailable;
      },
      what: 'the runtime to start warm',
      timeout: const Duration(minutes: 8),
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

    // ── The tombstones ──────────────────────────────────────────────────
    await pumpUntil(
      tester,
      () => panel().tabs.length >= 3,
      what: "part A's sessions as tabs",
    );
    final tabs = {for (final tab in panel().tabs) tab.label: tab};
    report(
      'tombstones ${[for (final tab in panel().tabs) '${tab.sessionId}:${tab.label}:${tab.ending}'].join(',')}',
    );
    expect(tabs.keys, containsAll(['seven', 'heartbeat', 'Terminal 1']));
    expect(tabs['heartbeat']!.ending, 'ended by the system');
    expect(tabs['Terminal 1']!.ending, 'ended by the system');
    expect(tabs['seven']!.ending, 'exited with code 7');
    expect(panel().tabs.where((tab) => tab.running), isEmpty);
    expect(panel().active?.label, 'Terminal 1', reason: 'the last one shows');
    await tester.pumpAndSettle();
    expect(find.text('Terminal 1 ended by the system.'), findsOneWidget);
    final idle = await gate.ask('service');
    expect(idle, 'none', reason: 'no service for tombstones');

    // ── A new session: above them, and the service with it ──────────────
    Future<int> newShell(String what) async {
      final before = {for (final tab in panel().tabs) tab.sessionId};
      await terminals.newSession();
      await pumpUntil(
        tester,
        () =>
            !before.contains(panel().activeId) &&
            (panel().active?.running ?? false) &&
            panel().viewPhase == TerminalViewPhase.ready,
        what: what,
      );
      return panel().activeId!;
    }

    Future<TerminalSnapshot> screenOf(
      int id,
      bool Function(TerminalSnapshot screen) ok, {
      required String what,
    }) async {
      final watch = Stopwatch()..start();
      TerminalSnapshot? last;
      while (watch.elapsed < const Duration(seconds: 30)) {
        final snapshot = await view.snapshot(id);
        if (snapshot case Ok(:final value)) {
          last = value;
          if (ok(value)) {
            return value;
          }
        }
        await tester.pump(const Duration(milliseconds: 200));
      }
      fail(
        'Timed out waiting for $what. The screen:\n${last?.screen.join('\n')}',
      );
    }

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

    Future<String> serviceWhere(bool Function(String answer) ok) async {
      var answer = await gate.ask('service');
      for (var tries = 0; tries < 20 && !ok(answer); tries++) {
        await tester.pump(const Duration(milliseconds: 500));
        answer = await gate.ask('service');
      }
      return answer;
    }

    final highest = tabs.values
        .map((tab) => tab.sessionId)
        .reduce((a, b) => a > b ? a : b);
    final fresh = await newShell('a new session');
    expect(fresh, greaterThan(highest), reason: 'ids go above the tombstones');
    await screenOf(fresh, promptAtCursor, what: 'the new prompt');
    await type(
      fresh,
      r'echo cf-after-$((6 * 7))'
      '\r',
    );
    await screenOf(
      fresh,
      (screen) => screen.screen.any((line) => line.trim() == 'cf-after-42'),
      what: 'the new session to answer',
    );
    final one = await serviceWhere((answer) => answer.startsWith('fg:1,'));
    expect(one, startsWith('fg:1,'));
    expect(one, contains('title:1-terminal-session-running'));
    await terminals.close(fresh);
    final stopped = await serviceWhere((answer) => answer == 'none');
    expect(stopped, 'none', reason: 'the service outlived the last session');
    report('service with_new=$one after_last=$stopped new_id=$fresh');

    // ── A tombstone closed is forgotten ─────────────────────────────────
    final seven = tabs['seven']!.sessionId;
    await terminals.close(seven);
    await tester.pump();
    final listed = switch (await service.sessions()) {
      Ok(:final value) => [for (final info in value) info.id],
      Err(:final failure) => fail('No listing: ${failure.message}'),
    };
    expect(listed, isNot(contains(seven)));
    expect(listed, containsAll([tabs['heartbeat']!.sessionId]));

    // ── One more, left running for the force-stop ────────────────────────
    final last = await newShell('the last session');
    await screenOf(last, promptAtCursor, what: 'the last prompt');
    await type(last, 'sleep $forceStopMarker &\r');
    await screenOf(
      last,
      (screen) =>
          screen.screen.any((line) => line.startsWith('[1] ')) &&
          promptAtCursor(screen),
      what: 'the job to start',
    );
    final job = await gate.ask('procs $forceStopMarker');
    expect(job, startsWith('count:1,'), reason: job);
    report('part_b=ok listed=${listed.join(',')} job=$job');
    gate.done();
  }, timeout: const Timeout(Duration(minutes: 15)));
}
