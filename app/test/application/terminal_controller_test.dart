/// TerminalController (Phase 5 W3) between a scripted TerminalService and a
/// scripted terminal page: sessions and tabs, output to the page with its
/// credit, input to the session, sizes, extra keys, and the page's restart.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/terminal/terminal_controller.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/terminal/terminal_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_terminal_surface.dart';
import '../support/scripted_terminal_service.dart';

void main() {
  late ScriptedTerminalService service;
  late List<FakeTerminalSurface> surfaces;
  late ProviderContainer container;

  setUp(() {
    service = ScriptedTerminalService();
    surfaces = [];
    container = ProviderContainer(
      overrides: [
        terminalServiceProvider.overrideWithValue(service),
        ...fakeTerminalOverrides(surfaces.add),
        currentWorkspaceProvider.overrideWithValue(const DemoProjectLocation()),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await service.dispose();
    });
    container.read(terminalControllerProvider);
  });

  TerminalController controller() =>
      container.read(terminalControllerProvider.notifier);
  TerminalPanelState state() => container.read(terminalControllerProvider);
  FakeTerminalSurface page() => surfaces.single;

  Future<int> start() async {
    await controller().newSession();
    await pumpEventQueue();
    return state().activeId!;
  }

  test('a new session starts in the project’s folder and is shown', () async {
    expect(state().available, isTrue);
    expect(state().tabs, isEmpty);
    final id = await start();
    final spec = service.specs.single;
    expect(spec.project, demoProjectFolder);
    expect(spec.label, 'Terminal 1');
    expect((spec.rows, spec.columns), (24, 80));
    expect(state().tabs.single.label, 'Terminal 1');
    expect(state().tabs.single.running, isTrue);
    expect(page().activeId, id);
    // The page fitted the view to the panel: the session takes that size,
    // and the next one starts at it.
    expect(service.resizes.last, (id: id, rows: 18, columns: 64));
    await start();
    expect(service.specs.last.label, 'Terminal 2');
    expect((service.specs.last.rows, service.specs.last.columns), (18, 64));
    expect(page().rejected, isEmpty);
  });

  test('output waits for its view, then arrives in order, credited', () async {
    // Output can come before the start that made it returns.
    service.emitOutput(1, text: 'early ');
    final id = await start();
    expect(id, 1);
    service.emitOutput(1, text: 'later');
    await pumpEventQueue();
    expect(page().sessions[1]!.written.toString(), 'early later');
    expect(service.acknowledged[1], [6, 11]);
  });

  test('credit follows the page’s parsing, not the delivery', () async {
    final id = await start();
    page().autoAck = false;
    service.emitOutput(id, text: 'one');
    service.emitOutput(id, text: 'two');
    await pumpEventQueue();
    expect(service.acknowledged[id], isNull);
    page().acknowledge();
    await pumpEventQueue();
    expect(service.acknowledged[id], [3]);
    page().acknowledge();
    await pumpEventQueue();
    expect(service.acknowledged[id], [3, 6]);
  });

  test('a UTF-8 character split between batches arrives whole', () async {
    final id = await start();
    final bytes = utf8.encode('é€😀');
    service.emitOutput(id, bytes: bytes.sublist(0, 1));
    service.emitOutput(id, bytes: bytes.sublist(1, 4));
    service.emitOutput(id, bytes: bytes.sublist(4));
    await pumpEventQueue();
    expect(page().sessions[id]!.written.toString(), 'é€😀');
    expect(service.acknowledged[id], [1, 4, bytes.length]);
  });

  test(
    'typed text reaches the session as UTF-8, mouse reports as bytes',
    () async {
      final id = await start();
      page().type(id, 'ls é\r');
      page().type(id, '\u001b[M \u00a1!', binary: true);
      await pumpEventQueue();
      expect(service.writes[id]![0], utf8.encode('ls é\r'));
      expect(
        service.writes[id]![1],
        Uint8List.fromList([0x1b, 0x5b, 0x4d, 0x20, 0xa1, 0x21]),
      );
    },
  );

  test('the panel’s size becomes the session’s', () async {
    final id = await start();
    page().resize(id, columns: 100, rows: 30);
    await pumpEventQueue();
    expect(service.resizes.last, (id: id, rows: 30, columns: 100));
  });

  test('closing a running session ends it, and the host forgets it', () async {
    final first = await start();
    final second = await start();
    controller().activate(first);
    await controller().close(first);
    await pumpEventQueue();
    expect(service.ended, [first]);
    expect(service.removed, [first]);
    expect(state().tabs.map((tab) => tab.sessionId), [second]);
    expect(state().activeId, second);
    expect(page().sessions.keys, [second]);
    expect(page().activeId, second);
  });

  test('closing an ended session only forgets it', () async {
    final id = await start();
    service.exit(id, code: 3);
    await pumpEventQueue();
    expect(state().tabs.single.ending, 'exited with code 3');
    await controller().close(id);
    expect(service.ended, isEmpty);
    expect(service.removed, [id]);
    expect(state().tabs, isEmpty);
    expect(state().activeId, isNull);
  });

  test('a tab takes a name, and gives it back', () async {
    final id = await start();
    controller().rename(id, '  server  ');
    expect(state().tabs.single.label, 'server');
    controller().rename(id, '');
    expect(state().tabs.single.label, 'Terminal 1');
  });

  test('stepping through the tabs wraps around', () async {
    final a = await start();
    final b = await start();
    final c = await start();
    expect(state().activeId, c);
    controller().step(1);
    expect(state().activeId, a);
    controller().step(-1);
    expect(state().activeId, c);
    controller().step(-1);
    expect(state().activeId, b);
  });

  test('an extra key takes the latched Ctrl along, and releases it', () async {
    final id = await start();
    controller().toggleCtrl();
    await pumpEventQueue();
    expect(state().ctrl, isTrue);
    expect(page().modifiers, (ctrl: true, alt: false));
    await controller().sendKey('up');
    await pumpEventQueue();
    expect(page().keys.single, (
      sessionId: id,
      key: 'up',
      ctrl: true,
      alt: false,
    ));
    expect(state().ctrl, isFalse);
    expect(page().modifiers, (ctrl: false, alt: false));
    // A key typed on the keyboard uses them up in the page.
    controller().toggleAlt();
    await pumpEventQueue();
    page().releaseModifiers();
    await pumpEventQueue();
    expect(state().alt, isFalse);
  });

  test('a page restart opens every view again and refills it', () async {
    final first = await start();
    final second = await start();
    service.emitOutput(first, text: 'one\r\n');
    service.emitOutput(second, text: 'two\r\n');
    await pumpEventQueue();
    service.buffers[first] = Uint8List.fromList(utf8.encode('one\r\n'));
    service.buffers[second] = Uint8List.fromList(utf8.encode('two\r\n'));
    page().restartPage();
    await pumpEventQueue();
    expect(page().sessions.keys.toSet(), {first, second});
    expect(page().activeId, second);
    expect(page().sessions[first]!.written.toString(), 'one\r\n');
    expect(page().sessions[second]!.written.toString(), 'two\r\n');
    service.emitOutput(first, text: 'after');
    await pumpEventQueue();
    expect(page().sessions[first]!.written.toString(), 'one\r\nafter');
  });

  test('a refused start says why; eight sessions are the most', () async {
    service.failNextStart = const TerminalFailure(
      'The Linux runtime is not ready yet.',
      problem: TerminalProblem.notReady,
    );
    await controller().newSession();
    expect(state().message, 'The Linux runtime is not ready yet.');
    expect(state().tabs, isEmpty);
    controller().dismissMessage();
    expect(state().message, isNull);
    for (var i = 0; i < maxTerminalSessions; i++) {
      await start();
    }
    expect(state().canStart, isFalse);
    await controller().newSession();
    expect(service.specs, hasLength(maxTerminalSessions + 1));
    expect(state().message, contains('Eight terminals'));
  });

  test(
    'a bell marks a hidden tab until it is shown; titles reach tabs',
    () async {
      final first = await start();
      final second = await start();
      page().bell(first);
      page().bell(second);
      page().title(second, 'top');
      await pumpEventQueue();
      expect(state().tabs.first.bell, isTrue);
      expect(state().tabs.last.bell, isFalse);
      expect(state().tabs.last.title, 'top');
      controller().activate(first);
      expect(state().tabs.first.bell, isFalse);
    },
  );

  test('End all ends every session', () async {
    await start();
    await start();
    await controller().endAll();
    await pumpEventQueue();
    expect(service.endAllCalls, 1);
    expect(state().tabs.every((tab) => !tab.running), isTrue);
    expect(state().tabs.first.state, TerminalSessionState.exited);
  });
}
