/// Gate G3, the terminal group (Phase 5 W3), and since W6 gate G6's figures
/// on the emulator: the terminal page (xterm.js) in the real app, with a
/// session on the sealed runtime.
///   1. Typed text echoes: the gate taps the terminal and types through
///      Android's input pipeline (`adb shell input text`, then Enter); the
///      shell echoes the command and runs it. The tap brings up the soft
///      keyboard (Gboard, beside the emulator's hardware keyboard), which
///      then goes down again, as the keyboard key leaves it.
///   2. G6's measurements (terminal_measure.dart): echo, the 10 MiB flood
///      with Flutter's frames and the page's, and the memory, with xterm.js's
///      DOM renderer, then WebGL, then the DOM's again. The memory before
///      any terminal is sampled with the editor open on main.js; the gate's
///      folder driver answers `mem` (dumpsys meminfo).
///   3. nano, top, less and the node REPL draw at the panel's size, in
///      portrait, after a turn to landscape and after the turn back: `stty
///      size` says the page's size, nano's title sits on the top row (its
///      name in the middle) and its shortcuts on the two bottom rows, top's
///      lines fit the width without wrapping, less fills every row above its
///      prompt, and node says the size it reads. nano is open while the
///      phone turns to landscape, and less while it turns back: each redraws
///      at the new size. The panel is maximized (the full stop): beside the
///      editor on a phone on its side, the dock alone has a row or two.
///   4. Scripted composition loses nothing: with `cat > .cf-compose.txt`
///      running, the soft keyboard down and the input methods off, the
///      gate's DevTools driver (editor/tool/terminal_cdp.mjs) plays the
///      composition suite into the page and compares the file with the
///      cases, line by line; this test waits for its end mark.
///
/// The input comes from outside the app, as in the keys group: the test asks
/// in the device log (`TERMGATE <run>.<n> tap <x> <y>`, `text <word>`,
/// `key <KEYCODE>`, `rotate <0|1>`, `compose`, `done`) and
/// app/tool/ci/emulator_gate.sh answers. The gate reads the TERMINAL_GATE
/// lines, and joins the measurements' TERMINAL_JSON report into
/// terminal_measure.json.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:codeforge/app.dart';
import 'package:codeforge/application/keyboard_state.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/application/shell_controller.dart';
import 'package:codeforge/application/terminal/terminal_controller.dart';
import 'package:codeforge/application/terminal/terminal_providers.dart';
import 'package:codeforge/application/terminal/terminal_view.dart';
import 'package:codeforge/core/errors/failure.dart';
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
import 'terminal_measure.dart';

/// The prompt CodeForge's rc file gives bash in the demo project.
const String _prompt = r'demo $';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('terminal: echo, G6’s figures, programs at the panel’s size, '
      'composition', (tester) async {
    final run = DateTime.now().millisecondsSinceEpoch;
    var step = 0;
    final ratio = tester.view.devicePixelRatio;
    // A print inside a test goes to the test runner, not the device log:
    // the requests are printed in the root zone (see keys_test.dart).
    void ask(String request) {
      step += 1;
      final line = 'TERMGATE $run.$step $request';
      Zone.root.print(line);
      debugPrint(line);
    }

    void report(String line) => debugPrint('TERMINAL_GATE $line');

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

    // The memory before any terminal (G6): the editor open on main.js.
    final gate = await FolderGate.start();
    final memory = memoryFrom(
      (request) => gate.ask(request, timeout: const Duration(seconds: 90)),
    );
    await openInEditor(tester, container, 'main.js');
    await tester.pump(const Duration(seconds: 3));
    final before = await memory('before');
    report(
      'memory before app_mb=${before.megabytes(before.appKb)} '
      'renderer_mb=${before.megabytes(before.rendererKb)} '
      'renderers=${before.renderers}',
    );

    // The terminal at its full stop, and a session in it.
    container
        .read(shellControllerProvider.notifier)
        .setTerminalStop(TerminalStop.full);
    await tester.pumpAndSettle();
    final starting = Stopwatch()..start();
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
    expect(panel.viewPhase, TerminalViewPhase.ready, reason: panel.viewMessage);
    final id = panel.activeId!;
    final view = container.read(terminalViewProvider);
    final service = container.read(terminalServiceProvider);

    Future<TerminalSnapshot> screenWhere(
      bool Function(TerminalSnapshot screen) ok, {
      required String what,
      Duration timeout = const Duration(seconds: 30),
    }) async {
      final watch = Stopwatch()..start();
      TerminalSnapshot? last;
      while (watch.elapsed < timeout) {
        final snapshot = await view.snapshot(id);
        if (snapshot case Ok(:final value)) {
          last = value;
          if (ok(value)) {
            return value;
          }
        }
        await tester.pump(const Duration(milliseconds: 150));
      }
      fail(
        'Timed out after ${timeout.inSeconds} s waiting for $what. The '
        'screen (${last?.columns}x${last?.rows}):\n${last?.screen.join('\n')}',
      );
    }

    Future<void> write(String text) async {
      final written = await service.write(
        id,
        Uint8List.fromList(utf8.encode(text)),
      );
      expect(written.isOk, isTrue, reason: '$written');
    }

    bool promptAtCursor(TerminalSnapshot screen) =>
        screen.cursorY < screen.screen.length &&
        screen.screen[screen.cursorY].contains(_prompt);

    final prompt = await screenWhere(
      promptAtCursor,
      what: 'the prompt',
      timeout: const Duration(seconds: 60),
    );
    report(
      'started ms=${starting.elapsedMilliseconds} '
      'size=${prompt.columns}x${prompt.rows}',
    );
    final opened = await memory('opened');

    // 1. Typed text echoes.
    final surface = find.byKey(const ValueKey('terminal_surface'));
    // Touches from the device reach the app only when the binding lets them
    // through: it drops them by default, which kept the first gate's tap
    // from the page. The flag goes back after each tap, as the binding
    // checks at the end of the test.
    Future<void> tapToFocus({required String what}) async {
      final centre = tester.getCenter(surface);
      final x = (centre.dx * ratio).round();
      final y = (centre.dy * ratio).round();
      binding.shouldPropagateDevicePointerEvents = true;
      try {
        ask('tap $x $y');
        await tester.pump(const Duration(seconds: 1));
        await pumpUntil(
          tester,
          () => container.read(terminalControllerProvider).focused,
          what: what,
        );
      } finally {
        binding.shouldPropagateDevicePointerEvents = false;
      }
    }

    await tapToFocus(what: 'the terminal to take the keyboard after a tap');
    ask('text echo%scf-typed-ok');
    await screenWhere(
      (screen) => screen.screen.any(
        (line) => line.contains('$_prompt echo cf-typed-ok'),
      ),
      what: 'the typed command to echo',
    );
    ask('key 66');
    await screenWhere(
      (screen) =>
          screen.screen.contains('cf-typed-ok') && promptAtCursor(screen),
      what: 'the typed command to run',
    );
    report('typed_echo=ok');

    // The panel's size is measured without the soft keyboard the tap brought
    // up, as the extra-keys row's keyboard key leaves it: with the keyboard
    // up, a phone on its side leaves the terminal a row.
    bool focusedNow() => container.read(terminalControllerProvider).focused;
    bool keyboardUp() => container.read(softKeyboardVisibleProvider);
    final terminals = container.read(terminalControllerProvider.notifier);
    await terminals.focus(focused: false);
    await pumpUntil(
      tester,
      () => !focusedNow() && !keyboardUp(),
      what: 'the soft keyboard to go down',
    );

    // 2. G6's measurements, with each renderer.
    final demo = '${await applicationFilesPath()}/workspaces/demo';
    final measured = await measureTerminal(
      tester: tester,
      binding: binding,
      view: view,
      id: id,
      folder: demo,
      write: write,
      promptShown: (what) => screenWhere(promptAtCursor, what: what),
      memory: memory,
      before: before,
      opened: opened,
      report: (line) => report('measure $line'),
      outputStats: () => terminals.outputStats,
    );
    report(
      'measure verdict echo_p95_ms=${measured.shippedEcho.p95Ms} '
      'flood_whole=${measured.flood.values.every((f) => f.whole) ? 1 : 0} '
      'ui_slow_pct=${measured.shippedFlood.ui.slowPct} '
      'memory_delta_mb=${measured.deltaMb} '
      'memory_peak_delta_mb=${measured.peakDeltaMb} '
      'webgl=${measured.webglRenderer} other_failure=${measured.otherFailure}',
    );
    expect(measured.shippedEcho.lost, 0);
    for (final flood in measured.flood.values) {
      expect(flood.whole, isTrue, reason: 'the flood (${flood.line()})');
    }
    await printReport('TERMINAL_JSON', measured.toJson());

    // 3. nano, top, less and node at the panel's size.
    Future<TerminalSnapshot> settledSize() async {
      var previous = await screenWhere((_) => true, what: 'a snapshot');
      for (var tries = 0; tries < 40; tries++) {
        await tester.pump(const Duration(milliseconds: 400));
        final next = await screenWhere((_) => true, what: 'a snapshot');
        if (next.columns == previous.columns && next.rows == previous.rows) {
          return next;
        }
        previous = next;
      }
      return previous;
    }

    /// nano drawn at [columns] x [rows]: its title centred on the top row,
    /// its shortcuts on the two bottom rows (from five rows up), nothing
    /// wrapped.
    void nanoFits(TerminalSnapshot nano, String where) {
      final columns = nano.columns;
      final rows = nano.rows;
      if (rows >= 5) {
        expect(nano.screen.last, contains('^X'), reason: where);
        expect(nano.screen[rows - 2], contains('^G'), reason: where);
      }
      expect(nano.wrapped, 0, reason: where);
      final title = nano.screen.first;
      const name = 'New Buffer';
      final at = title.indexOf(name);
      expect(at, greaterThan(0), reason: 'nano\'s title ($where): "$title"');
      final middle = at + name.length / 2;
      expect(
        (middle - columns / 2).abs(),
        lessThanOrEqualTo(columns / 6),
        reason: 'nano centres "$name" on $columns columns ($where): "$title"',
      );
    }

    /// less with `seq 1 1000` at [rows]: a number on every row above its
    /// prompt, the prompt on the last row.
    bool lessFills(TerminalSnapshot screen, int rows) =>
        screen.alternate &&
        screen.rows == rows &&
        screen.screen.first.trim() == '1' &&
        screen.screen[rows - 2].trim() == '${rows - 1}' &&
        screen.screen.last.startsWith(':');

    Future<({int columns, int rows})> checkFits(String where) async {
      final size = await settledSize();
      final columns = size.columns;
      final rows = size.rows;
      await write('clear; stty size\r');
      await screenWhere(
        (screen) =>
            screen.screen.any((line) => line.trim() == '$rows $columns'),
        what: 'stty size to say "$rows $columns" ($where)',
      );
      await screenWhere(promptAtCursor, what: 'the prompt after stty ($where)');

      // nano keeps its two rows of shortcuts from five rows up.
      final help = rows >= 5;
      await write('nano\r');
      final nano = await screenWhere(
        (screen) =>
            screen.alternate &&
            screen.screen.first.contains('GNU nano') &&
            (!help || screen.screen.last.contains('^X')),
        what: 'nano to draw ($where)',
      );
      expect((nano.columns, nano.rows), (columns, rows));
      nanoFits(nano, where);
      await write('\u0018'); // Ctrl-X: nano exits, with nothing to save
      await screenWhere(
        (screen) => !screen.alternate && promptAtCursor(screen),
        what: 'nano to exit ($where)',
      );

      await write('clear; top\r');
      final top = await screenWhere(
        (screen) => screen.screen.any((line) => line.contains('PID')),
        what: 'top to draw ($where)',
      );
      // Give it a refresh at the size it read, then look again.
      await tester.pump(const Duration(milliseconds: 1500));
      final drawn = await screenWhere(
        (screen) => screen.screen.any((line) => line.contains('PID')),
        what: 'top to draw again ($where)',
      );
      for (final screen in [top, drawn]) {
        expect(screen.wrapped, 0, reason: 'top wrapped lines ($where)');
        for (final line in screen.screen) {
          expect(
            line.length,
            lessThanOrEqualTo(columns),
            reason: 'top wrote past $columns columns ($where): "$line"',
          );
        }
      }
      await write('q');
      await screenWhere(promptAtCursor, what: 'top to exit ($where)');

      // less fills the rows above its prompt.
      await write('clear; seq 1 1000 | less\r');
      final less = await screenWhere(
        (screen) => lessFills(screen, rows),
        what: 'less to fill $rows rows ($where)',
      );
      expect(less.wrapped, 0, reason: 'less wrapped lines ($where)');
      await write('q');
      await screenWhere(
        (screen) => !screen.alternate && promptAtCursor(screen),
        what: 'less to exit ($where)',
      );

      // node's REPL reads the size from the terminal, as any program does.
      await write('clear; node\r');
      // The snapshot trims trailing spaces: node's prompt shows as ">".
      await screenWhere(
        (screen) =>
            screen.cursorY < screen.screen.length &&
            screen.screen[screen.cursorY].trim() == '>',
        what: 'node\'s prompt ($where)',
        timeout: const Duration(seconds: 60),
      );
      await write("process.stdout.columns + 'x' + process.stdout.rows\r");
      await screenWhere(
        (screen) =>
            screen.screen.any((line) => line.trim() == "'${columns}x$rows'"),
        what: 'node to say ${columns}x$rows ($where)',
      );
      await write('.exit\r');
      await screenWhere(promptAtCursor, what: 'node to exit ($where)');
      report(
        'fit where=$where columns=$columns rows=$rows stty=ok nano=ok '
        'top=ok top_lines=${drawn.screen.where((l) => l.isNotEmpty).length} '
        'less=ok node=ok',
      );
      return (columns: columns, rows: rows);
    }

    final portrait = await checkFits('portrait');

    // nano is open while the phone turns: it redraws at the new size.
    await write('clear; nano\r');
    await screenWhere(
      (screen) => screen.alternate && screen.screen.first.contains('GNU nano'),
      what: 'nano to draw before the turn',
    );
    ask('rotate 1');
    await screenWhere(
      (screen) => screen.columns > portrait.columns,
      what: 'the terminal to widen in landscape',
    );
    final widened = await settledSize();
    final turnedNano = await screenWhere(
      (screen) =>
          screen.columns == widened.columns &&
          screen.alternate &&
          screen.screen.first.contains('GNU nano') &&
          (screen.rows < 5 || screen.screen.last.contains('^X')),
      what: 'nano to redraw in landscape',
    );
    nanoFits(turnedNano, 'nano across the turn to landscape');
    await write('\u0018');
    await screenWhere(
      (screen) => !screen.alternate && promptAtCursor(screen),
      what: 'nano to exit after the turn',
    );
    report(
      'turn to=landscape program=nano columns=${turnedNano.columns} '
      'rows=${turnedNano.rows} redrawn=ok',
    );
    final landscape = await checkFits('landscape');

    // less is open while it turns back: it fills the new rows.
    await write('clear; seq 1 1000 | less\r');
    await screenWhere(
      (screen) => lessFills(screen, landscape.rows),
      what: 'less to draw before the turn back',
    );
    ask('rotate 0');
    await screenWhere(
      (screen) => screen.columns < landscape.columns,
      what: 'the terminal to narrow in portrait again',
    );
    final narrowed = await settledSize();
    final turnedLess = await screenWhere(
      (screen) =>
          screen.columns == narrowed.columns &&
          lessFills(screen, narrowed.rows),
      what: 'less to redraw in portrait',
    );
    await write('q');
    await screenWhere(
      (screen) => !screen.alternate && promptAtCursor(screen),
      what: 'less to exit after the turn',
    );
    report(
      'turn to=portrait program=less columns=${turnedLess.columns} '
      'rows=${turnedLess.rows} redrawn=ok',
    );
    await checkFits('portrait again');

    // 4. Scripted composition loses nothing.
    final file = File(
      '${await applicationFilesPath()}/workspaces/demo/.cf-compose.txt',
    );
    if (file.existsSync()) {
      file.deleteSync();
    }
    await write('cat > .cf-compose.txt\r');
    await screenWhere(
      (screen) => screen.screen.any(
        (line) => line.endsWith('$_prompt cat > .cf-compose.txt'),
      ),
      what: 'cat to start',
    );
    // A tap gives the page the app's focus again after the turns, then the
    // keyboard goes down. The suite's compositions are scripted (DevTools),
    // and a connected input method finishes any composition it did not
    // start, shown or not (Gboard committed every step of every case in
    // phase gates 44589259655 and 44596547784): the driver turns the input
    // methods off while it plays, and focuses the terminal's input itself.
    await tapToFocus(
      what: 'the terminal to have the keyboard before the composition',
    );
    await terminals.focus(focused: false);
    await pumpUntil(
      tester,
      () => !focusedNow() && !keyboardUp(),
      what: 'the soft keyboard to go down before the composition',
    );
    ask('compose');
    final composing = Stopwatch()..start();
    while (!(file.existsSync() &&
        file.readAsLinesSync().contains('COMPOSE-END'))) {
      if (composing.elapsed > const Duration(minutes: 5)) {
        fail(
          'The composition suite never ended. The file: '
          '${file.existsSync() ? file.readAsStringSync() : '(none)'}',
        );
      }
      await tester.pump(const Duration(milliseconds: 250));
    }
    await write('\u0004'); // cat ends at the start of a line
    await screenWhere(promptAtCursor, what: 'cat to end');
    final lines = file.readAsLinesSync();
    report(
      'compose_lines=${lines.length} compose_ms=${composing.elapsedMilliseconds}',
    );
    expect(lines.last, 'COMPOSE-END');
    expect(lines.where((line) => line.isEmpty), isEmpty);

    ask('done');
    gate.done();
    await container.read(terminalControllerProvider.notifier).close(id);
    await tester.pumpAndSettle();
    report('closed=ok dropped_messages=${view.droppedMessages}');
    expect(view.droppedMessages, 0);
  }, timeout: const Timeout(Duration(minutes: 30)));
}
