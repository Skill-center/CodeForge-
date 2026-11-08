/// Keyboards on the real page in the emulator (Phase 2 W6, gate G6).
///
/// The input comes from outside the app, as a user's does. The test asks for
/// it in the log, one numbered request at a time (`KEYGATE <n> tap <x> <y>`,
/// `KEYGATE <n> key <KEYCODE>`, `KEYGATE <n> keys <KEYCODE> <KEYCODE>…`), and
/// app/tool/ci/emulator_gate.sh answers through Android's input pipeline
/// with `adb shell input tap`, `input keyevent` and `input keycombination`.
/// So a toolbar key is touched as a finger touches it, which `tester.tap`
/// cannot do (it never leaves Flutter), and a shortcut arrives from a
/// keyboard at the focused WebView. Each request is followed by a wait for
/// what it should have done.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/editor/editor_status.dart';
import 'package:codeforge/application/editor/find_controller.dart';
import 'package:codeforge/application/keyboard_state.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp, pumpUntil;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keys: toolbar touches and hardware shortcuts on the real page', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await pumpRealApp(tester, prefs);
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final host = container.read(editorHostProvider);
    await pumpUntil(
      tester,
      () =>
          host.status.phase == EditorHostPhase.ready ||
          host.status.phase == EditorHostPhase.failed,
      what: 'the editor page to start',
    );
    expect(
      host.status.phase,
      EditorHostPhase.ready,
      reason: host.status.message,
    );
    await pumpUntil(tester, () => host.syncs >= 1, what: 'the first sync');

    // MainActivity answers for the hardware keyboard; the gate's Pixel 6
    // has none, so the toolbar shows.
    final attached = await const MethodChannel(
      'dev.codeforge/keyboard',
    ).invokeMethod<bool>('attached');
    expect(attached, isFalse);
    expect(container.read(hardwareKeyboardProvider), isFalse);

    final files = container.read(fileServiceProvider);
    final documents = container.read(documentControllerProvider.notifier);
    const seeds = [('g6/other.js', 'y\n'), ('g6/keys.js', 'x\n')];
    for (final (path, text) in seeds) {
      final written = await files.writeText(
        path,
        text,
        mode: WriteMode.createNew,
      );
      expect(written.isOk, isTrue, reason: path);
      expect((await documents.open(path)).isOk, isTrue, reason: path);
    }
    await tester.pumpAndSettle();
    final docId = container
        .read(documentControllerProvider)
        .documents['g6/keys.js']!
        .docId;
    String? text() => host.textOf(docId);
    int? head() => host.viewStateOf(docId)?.selection?.head;
    bool focused() => container.read(editorStatusProvider).focused;
    bool keyboardUp() => container.read(softKeyboardVisibleProvider);
    String? activePath() =>
        container.read(documentControllerProvider).activePath;

    var step = 0;
    final ratio = tester.view.devicePixelRatio;
    Future<void> inject(
      String request,
      bool Function() done, {
      required String what,
    }) async {
      step += 1;
      debugPrint('KEYGATE $step $request');
      await pumpUntil(tester, done, what: '$what (request $step: $request)');
      // Let the page's trailing reports land before the next request.
      await tester.pump(const Duration(milliseconds: 400));
    }

    String tapOn(Finder finder) {
      final center = tester.getCenter(finder);
      final x = (center.dx * ratio).round();
      final y = (center.dy * ratio).round();
      return 'tap $x $y';
    }

    Future<void> cursorToStart() async {
      expect((await host.gotoLine(1)).isOk, isTrue);
      await pumpUntil(tester, () => head() == 0, what: 'the cursor at 0');
    }

    // A finger in the editor: it takes the keyboard, and the soft keyboard
    // comes up for it.
    await inject(
      tapOn(find.byKey(const ValueKey('editor_surface'))),
      focused,
      what: 'the editor to take the keyboard',
    );
    final ime = Stopwatch()..start();
    while (!keyboardUp() && ime.elapsed < const Duration(seconds: 15)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final imeUp = keyboardUp();
    debugPrint('keys: soft keyboard up after the tap: $imeUp');

    // Hardware keys at the focused WebView: CodeMirror's keymap.
    await cursorToStart();
    await inject(
      'key KEYCODE_TAB',
      () => text() == '  x\n',
      what: 'Tab to indent',
    );
    await inject(
      'keys KEYCODE_SHIFT_LEFT KEYCODE_TAB',
      () => text() == 'x\n',
      what: 'Shift+Tab to outdent',
    );
    await inject(
      'keys KEYCODE_CTRL_LEFT KEYCODE_Z',
      () => text() == '  x\n',
      what: 'Ctrl+Z to undo',
    );
    await inject(
      'keys KEYCODE_CTRL_LEFT KEYCODE_SHIFT_LEFT KEYCODE_Z',
      () => text() == 'x\n',
      what: 'Ctrl+Shift+Z to redo',
    );

    // Toolbar keys under a real finger: they type at the cursor, a pair
    // leaves it between its halves, and the editor keeps the keyboard.
    await cursorToStart();
    await inject(
      tapOn(find.byKey(const ValueKey('toolbar_symbol:()'))),
      () => text() == '()x\n' && head() == 1,
      what: 'the () key to type a pair around the cursor',
    );
    expect(focused(), isTrue, reason: 'a toolbar key took the focus');
    expect(keyboardUp(), imeUp, reason: 'a toolbar key moved the keyboard');
    await inject(
      tapOn(find.byKey(const ValueKey('toolbar_indent'))),
      () => text() == '( )x\n' && head() == 2,
      what: 'the Tab key to indent to the next stop',
    );
    expect(focused(), isTrue, reason: 'a toolbar key took the focus');
    expect(keyboardUp(), imeUp, reason: 'a toolbar key moved the keyboard');

    // App shortcuts, caught by the page and forwarded over the bridge.
    await inject(
      'keys KEYCODE_CTRL_LEFT KEYCODE_S',
      () =>
          container
              .read(documentControllerProvider)
              .documents['g6/keys.js']
              ?.dirty ==
          false,
      what: 'Ctrl+S to save',
    );
    final saved = await files.readText('g6/keys.js');
    expect(saved.valueOrNull?.text, '( )x\n');
    await inject(
      'keys KEYCODE_CTRL_LEFT KEYCODE_TAB',
      () => activePath() == 'g6/other.js',
      what: 'Ctrl+Tab to the next tab',
    );
    await inject(
      'keys KEYCODE_CTRL_LEFT KEYCODE_W',
      () =>
          activePath() == 'g6/keys.js' &&
          !container
              .read(documentControllerProvider)
              .openPaths
              .contains('g6/other.js'),
      what: 'Ctrl+W to close the tab',
    );
    await inject(
      'keys KEYCODE_CTRL_LEFT KEYCODE_F',
      () => container.read(findControllerProvider).open,
      what: 'Ctrl+F to open the find bar',
    );
    await inject(
      'key KEYCODE_ESCAPE',
      () => !container.read(findControllerProvider).open,
      what: 'Escape to close the find bar',
    );
    await inject(
      'keys KEYCODE_CTRL_LEFT KEYCODE_SHIFT_LEFT KEYCODE_P',
      () => find.byKey(const ValueKey('palette_input')).evaluate().isNotEmpty,
      what: 'Ctrl+Shift+P to open the palette',
    );
    await inject(
      'key KEYCODE_ESCAPE',
      () => find.byKey(const ValueKey('palette_input')).evaluate().isEmpty,
      what: 'Escape to close the palette',
    );
    debugPrint('KEYGATE ${step + 1} done');

    expect(host.droppedMessages, 0);
    expect(host.resyncs, 0);
    debugPrint(
      'keys: ok (toolbar () and Tab under a finger typed at the cursor and '
      'kept the focus, soft keyboard up throughout: $imeUp; Tab, Shift+Tab, '
      'Ctrl+Z, Ctrl+Shift+Z, Ctrl+S, Ctrl+Tab, Ctrl+W, Ctrl+F, Escape, '
      'Ctrl+Shift+P from the keyboard; resyncs ${host.resyncs})',
    );
  });
}
