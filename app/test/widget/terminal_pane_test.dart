/// The terminal panel (Phase 5 W3, gate G3's widget part): tabs (new,
/// switch by tap and by swipe, rename, close with a question while running),
/// the extra-keys row (keys in the terminal's modes, Ctrl latched for one
/// key), copy and paste through the clipboard, and a layout that fits every
/// stop. The page is scripted (test/support/fake_terminal_surface.dart) and
/// the sessions too (test/support/scripted_terminal_service.dart).
library;

import 'dart:async';

import 'package:codeforge/application/terminal/terminal_controller.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/features/workbench/panels/terminal_pane.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_terminal_surface.dart';
import '../support/scripted_terminal_service.dart';
import 'test_harness.dart';

/// Answers the clipboard: what a paste reads, and what a copy wrote.
final class _Clipboard {
  String? text;
  final List<String> copied = [];
}

_Clipboard _clipboard(WidgetTester tester, {String? text}) {
  final clipboard = _Clipboard()..text = text;
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.getData':
        final value = clipboard.text;
        return value == null ? null : <String, Object?>{'text': value};
      case 'Clipboard.setData':
        final arguments = call.arguments as Map<Object?, Object?>;
        clipboard.copied.add(arguments['text']! as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return clipboard;
}

final class _Pane {
  _Pane(this.harness, this.service);

  final TestHarness harness;
  final ScriptedTerminalService service;

  FakeTerminalSurface get page => harness.terminalSurfaces.single;
}

Future<_Pane> _pump(
  WidgetTester tester, {
  TerminalStop stop = TerminalStop.full,
  double width = 412,
  double height = 915,
}) async {
  setSurface(tester, width, height);
  final service = ScriptedTerminalService();
  addTearDown(service.dispose);
  final harness = TestHarness(
    shell: ShellState(lastRoute: '/workspace', terminalStop: stop),
    terminal: service,
  );
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  return _Pane(harness, service);
}

/// Starts a session as the panel's + does, in the test's fake time: the
/// page's messages are delivered as the frames settle.
Future<int> _start(WidgetTester tester) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(TerminalPane)),
  );
  unawaited(container.read(terminalControllerProvider.notifier).newSession());
  await tester.pumpAndSettle();
  return container.read(terminalControllerProvider).activeId!;
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('without a terminal host the pane says what it needs', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(
        lastRoute: '/workspace',
        terminalStop: TerminalStop.half,
      ),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    expect(find.text('TERMINAL'), findsOneWidget);
    expect(_key('terminal_unavailable'), findsOneWidget);
    expect(find.textContaining('on Android'), findsOneWidget);
    expect(_key('terminal_new'), findsNothing);
    expect(harness.terminalSurfaces.single.loads, 0);
  });

  testWidgets('New terminal opens a tab running in the project’s folder', (
    tester,
  ) async {
    final pane = await _pump(tester);
    expect(_key('terminal_empty'), findsOneWidget);
    // The page loads with the first terminal, not before.
    expect(pane.page.loads, 0);
    await tester.tap(_key('terminal_new_empty'));
    await tester.pumpAndSettle();
    expect(pane.service.specs.single.project, demoProjectFolder);
    expect(find.text('Terminal 1'), findsOneWidget);
    expect(_key('fake_terminal_page'), findsOneWidget);
    expect(_key('terminal_keys'), findsOneWidget);
    expect(pane.page.loads, 1);
    expect(pane.page.activeId, 1);
    // The appearance went to the page, and passed its validation.
    expect(pane.page.configuration?['theme'], isA<Map<String, Object?>>());
    expect(pane.page.rejected, isEmpty);
    pane.service.emitOutput(1, text: 'hello');
    await tester.pumpAndSettle();
    expect(pane.page.sessions[1]!.written.toString(), 'hello');
    expect(pane.service.acknowledged[1], [5]);
  });

  testWidgets('tabs switch by a tap and by a swipe across them', (
    tester,
  ) async {
    final pane = await _pump(tester);
    final first = await _start(tester);
    final second = await _start(tester);
    expect(find.text('Terminal 2'), findsOneWidget);
    expect(pane.page.activeId, second);
    await tester.tap(_key('terminal_tab_$first'));
    await tester.pumpAndSettle();
    expect(pane.page.activeId, first);
    await tester.fling(_key('terminal_tabs'), const Offset(-160, 0), 1000);
    await tester.pumpAndSettle();
    expect(pane.page.activeId, second);
    await tester.fling(_key('terminal_tabs'), const Offset(160, 0), 1000);
    await tester.pumpAndSettle();
    expect(pane.page.activeId, first);
  });

  testWidgets('a long press renames a tab', (tester) async {
    await _pump(tester);
    final id = await _start(tester);
    await tester.longPress(_key('terminal_tab_$id'));
    await tester.pumpAndSettle();
    expect(_key('terminal_rename_dialog'), findsOneWidget);
    await tester.enterText(_key('terminal_rename_field'), 'server');
    await tester.tap(_key('terminal_rename_confirm'));
    await tester.pumpAndSettle();
    expect(find.text('server'), findsOneWidget);
    expect(find.text('Terminal 1'), findsNothing);
  });

  testWidgets('closing a running terminal asks first; an ended one does not', (
    tester,
  ) async {
    final pane = await _pump(tester);
    final first = await _start(tester);
    final second = await _start(tester);
    await tester.tap(_key('terminal_tab_close_$second'));
    await tester.pumpAndSettle();
    expect(_key('terminal_close_dialog'), findsOneWidget);
    await tester.tap(_key('terminal_close_cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Terminal 2'), findsOneWidget);
    expect(pane.service.ended, isEmpty);

    await tester.tap(_key('terminal_tab_close_$second'));
    await tester.pumpAndSettle();
    await tester.tap(_key('terminal_close_confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Terminal 2'), findsNothing);
    expect(pane.service.ended, [second]);
    expect(pane.service.removed, [second]);
    expect(pane.page.activeId, first);

    pane.service.exit(first, code: 2);
    await tester.pumpAndSettle();
    expect(find.textContaining('exited with code 2'), findsOneWidget);
    // The keys go with the running session.
    expect(_key('terminal_keys'), findsNothing);
    await tester.tap(_key('terminal_tab_close_$first'));
    await tester.pumpAndSettle();
    expect(_key('terminal_close_dialog'), findsNothing);
    expect(pane.service.removed, [second, first]);
    expect(_key('terminal_empty'), findsOneWidget);
  });

  testWidgets('extra keys send their keys; Ctrl latches for one key', (
    tester,
  ) async {
    final pane = await _pump(tester);
    final id = await _start(tester);
    await _tapKey(tester, 'toolbar_terminal_esc');
    expect(pane.page.keys.last, (
      sessionId: id,
      key: 'escape',
      ctrl: false,
      alt: false,
    ));
    await _tapKey(tester, 'toolbar_terminal_tab');
    expect(pane.page.keys.last.key, 'tab');

    await _tapKey(tester, 'toolbar_terminal_ctrl');
    expect(pane.page.modifiers, (ctrl: true, alt: false));
    expect(
      tester.getSemantics(_key('toolbar_terminal_ctrl')),
      isSemantics(
        label: 'Control, for the next key',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
      ),
    );
    await _tapKey(tester, 'toolbar_terminal_left');
    expect(pane.page.keys.last, (
      sessionId: id,
      key: 'left',
      ctrl: true,
      alt: false,
    ));
    expect(pane.page.modifiers, (ctrl: false, alt: false));
    await _tapKey(tester, 'toolbar_terminal_pipe');
    expect(pane.page.keys.last, (
      sessionId: id,
      key: '|',
      ctrl: false,
      alt: false,
    ));

    // A key typed on the keyboard uses the latched Alt up in the page.
    await _tapKey(tester, 'toolbar_terminal_alt');
    expect(pane.page.modifiers, (ctrl: false, alt: true));
    pane.page.releaseModifiers();
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(_key('toolbar_terminal_alt')),
      isSemantics(
        label: 'Alt, for the next key',
        hasToggledState: true,
        isToggled: false,
      ),
    );
  });

  testWidgets('a selection offers Copy, which fills the clipboard', (
    tester,
  ) async {
    final clipboard = _clipboard(tester);
    final pane = await _pump(tester);
    final id = await _start(tester);
    expect(_key('toolbar_terminal_copy'), findsNothing);
    pane.page.select(id, 'hello world');
    await tester.pumpAndSettle();
    await _tapKey(tester, 'toolbar_terminal_copy');
    expect(clipboard.copied, ['hello world']);
    expect(pane.page.selects, ['none']);
    pane.page.select(id, '');
    await tester.pumpAndSettle();
    expect(_key('toolbar_terminal_copy'), findsNothing);
  });

  testWidgets('Paste sends the clipboard’s text to the page', (tester) async {
    _clipboard(tester, text: 'echo pasted\n');
    final pane = await _pump(tester);
    final id = await _start(tester);
    await _tapKey(tester, 'toolbar_terminal_paste');
    expect(pane.page.pastes.single, (sessionId: id, text: 'echo pasted\n'));
  });

  testWidgets('End all, from the menu, asks first', (tester) async {
    final pane = await _pump(tester);
    await _start(tester);
    await _start(tester);
    await tester.tap(_key('terminal_menu'));
    await tester.pumpAndSettle();
    await tester.tap(_key('terminal_menu_end_all'));
    await tester.pumpAndSettle();
    expect(_key('terminal_end_all_dialog'), findsOneWidget);
    expect(find.textContaining('2 terminals are running'), findsOneWidget);
    await tester.tap(_key('terminal_end_all_confirm'));
    await tester.pumpAndSettle();
    expect(pane.service.endAllCalls, 1);
  });

  testWidgets('the panel meets the tap-target and label guidelines', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    await _start(tester);
    await _start(tester);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  for (final (width, height, label) in const [
    (360.0, 800.0, 'small phone portrait'),
    (800.0, 360.0, 'phone landscape (short)'),
    (1280.0, 800.0, 'tablet landscape'),
  ]) {
    testWidgets('no overflow with terminals open: $label, at every stop', (
      tester,
    ) async {
      for (final stop in TerminalStop.values) {
        await tester.pumpWidget(const SizedBox.shrink());
        await _pump(tester, stop: stop, width: width, height: height);
        if (stop == TerminalStop.closed) {
          expect(find.byType(TerminalPane), findsNothing);
          continue;
        }
        if (find.byType(TerminalPane).evaluate().isEmpty) {
          continue; // a stop the layout hides at this size
        }
        await _start(tester);
        await _start(tester);
        expect(tester.takeException(), isNull, reason: stop.name);
        if (stop == TerminalStop.peek) {
          expect(_key('terminal_keys'), findsNothing);
        }
      }
    });
  }
}
