/// Keyboards on the real page in the emulator (Phase 2 W6, gate G6).
///
/// The input comes from outside the app, as a user's does. The test asks for
/// it in the log, one request at a time (`KEYGATE <id> tap <x> <y>`,
/// `KEYGATE <id> key <KEYCODE>`, `KEYGATE <id> keys <KEYCODE> <KEYCODE>…`;
/// the id is `<run>.<n>`, so a retried test's requests are new ones), and
/// app/tool/ci/emulator_gate.sh answers through Android's input pipeline
/// with `adb shell input tap`, `input keyevent` and `input keycombination`.
/// So a toolbar key is touched as a finger touches it, which `tester.tap`
/// cannot do (it never leaves Flutter), and a shortcut arrives from a
/// keyboard at the focused WebView. Each request is followed by a wait for
/// what it should have done.
///
/// AVDs report a hardware keyboard, the gate's included, and Android then
/// keeps the soft keyboard down unless its setting for showing it beside a
/// physical keyboard is on: the gate turns that on for this test. The test
/// checks MainActivity's answer against the app, and the toolbar against
/// both: away beside a hardware keyboard, back with the soft keyboard.
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
import 'package:codeforge/services/platform/hardware_keyboard.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpUntil;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keys: toolbar touches and hardware shortcuts on the real page', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final keyboard = _UnpluggableKeyboard();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(PrefsSettingsStore(prefs)),
          shellStateStoreProvider.overrideWithValue(
            PrefsShellStateStore(prefs),
          ),
          hardwareKeyboardSourceProvider.overrideWithValue(keyboard),
        ],
        child: const CodeForgeApp(),
      ),
    );
    await tester.pumpAndSettle();
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

    // MainActivity answers for the hardware keyboard from Android's
    // configuration. Beside one, the toolbar keeps away until a soft
    // keyboard comes up as well.
    final answer = await const MethodChannel(
      'dev.codeforge/keyboard',
    ).invokeMethod<bool>('attached');
    expect(answer, isNotNull, reason: 'MainActivity gave no answer');
    final attached = answer ?? false;
    await pumpUntil(
      tester,
      () => container.read(hardwareKeyboardProvider) == attached,
      what: 'the app to hear of the hardware keyboard',
    );
    await tester.pump(const Duration(milliseconds: 100));
    final toolbar = find.byKey(const ValueKey('symbol_toolbar'));
    final awayBeside = attached && !keyboardUp();
    expect(
      toolbar,
      awayBeside ? findsNothing : findsOneWidget,
      reason: 'hardware keyboard attached: $attached',
    );

    var step = 0;
    final run = DateTime.now().millisecondsSinceEpoch;
    final ratio = tester.view.devicePixelRatio;
    Future<void> inject(
      String request,
      bool Function() done, {
      required String what,
    }) async {
      step += 1;
      debugPrint('KEYGATE $run.$step $request');
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

    // The toolbar for the touches below. Beside a hardware keyboard it comes
    // with the soft keyboard; if none came, the test unplugs the keyboard
    // (the app hears of it as of a real one) to bring the toolbar out.
    final unplug = attached && !imeUp;
    if (unplug) {
      keyboard.unplugged = true;
      container.invalidate(hardwareKeyboardProvider);
    }
    await pumpUntil(
      tester,
      () => toolbar.evaluate().isNotEmpty,
      what: 'the symbol toolbar',
    );
    final shownBy = !attached
        ? 'no hardware keyboard'
        : unplug
        ? 'unplugging the hardware keyboard'
        : 'the soft keyboard beside the hardware one';
    debugPrint(
      'keys: hardware keyboard attached: $attached, toolbar away beside it: '
      '$awayBeside; soft keyboard up after the tap: $imeUp; toolbar shown '
      'by $shownBy',
    );

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
    debugPrint('KEYGATE $run.${step + 1} done');

    expect(host.droppedMessages, 0);
    expect(host.resyncs, 0);
    debugPrint(
      'keys: ok (toolbar () and Tab under a finger typed at the cursor and '
      'kept the focus, soft keyboard up throughout: $imeUp; hardware '
      'keyboard attached: $attached, toolbar shown by $shownBy; Tab, '
      'Shift+Tab, Ctrl+Z, Ctrl+Shift+Z, Ctrl+S, Ctrl+Tab, Ctrl+W, Ctrl+F, '
      'Escape, Ctrl+Shift+P from the keyboard; resyncs ${host.resyncs})',
    );
  });
}

/// The phone's own answer about a hardware keyboard until the test unplugs
/// it; then the app hears that the keyboard went, as from a real unplug.
final class _UnpluggableKeyboard implements HardwareKeyboardSource {
  final _phone = PlatformHardwareKeyboard();
  var unplugged = false;

  @override
  Stream<bool> watch() =>
      _phone.watch().map((attached) => attached && !unplugged);
}
