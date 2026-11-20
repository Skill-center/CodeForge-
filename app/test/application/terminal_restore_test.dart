/// Sessions that last (Phase 5 W5): the terminal controller takes the
/// host's sessions as tabs when it is made, those that kept running while
/// the app's engine was gone and the tombstones the app's last process left
/// ("ended by the system"); the shown one's buffer is drawn again at once,
/// the others' when their tab is shown. Under memory pressure it lets go of
/// the hidden sessions' views and draws one again from the host's buffer
/// when it is shown.
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

  ProviderContainer containerFor(ScriptedTerminalService terminals) {
    final container = ProviderContainer(
      overrides: [
        terminalServiceProvider.overrideWithValue(terminals),
        ...fakeTerminalOverrides(surfaces.add),
        currentWorkspaceProvider.overrideWithValue(const DemoProjectLocation()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    service = ScriptedTerminalService(firstId: 10);
    surfaces = [];
    addTearDown(() => service.dispose());
  });

  test('the host’s sessions and tombstones become tabs, drawn again', () async {
    // What the host holds when the app's engine starts: a tombstone the last
    // process left, and a session that kept running.
    service.infos[3] = const TerminalInfo(
      id: 3,
      label: 'Terminal 1',
      state: TerminalSessionState.exited,
      rows: 24,
      columns: 80,
      received: 0,
      problem: TerminalProblem.system,
    );
    service.infos[5] = const TerminalInfo(
      id: 5,
      label: 'npm run build',
      state: TerminalSessionState.running,
      rows: 24,
      columns: 80,
      received: 6,
    );
    service.buffers[5] = Uint8List.fromList(utf8.encode('built\n'));
    final container = containerFor(service);
    container.read(terminalControllerProvider);
    await pumpEventQueue();

    final panel = container.read(terminalControllerProvider);
    expect([for (final tab in panel.tabs) tab.sessionId], [3, 5]);
    expect(panel.activeId, 5, reason: 'the running one shows');
    final tombstone = panel.tabs.first;
    expect(tombstone.label, 'Terminal 1');
    expect(tombstone.running, isFalse);
    expect(tombstone.ending, 'ended by the system');
    expect(panel.tabs.last.label, 'npm run build');
    // The shown one's view drew its buffer; the tombstone's waits.
    final page = surfaces.single;
    expect(page.sessions.keys, [5]);
    expect(page.sessions[5]!.written.toString(), 'built\n');
    expect(page.activeId, 5);

    // Shown, the tombstone gets its view: nothing to draw.
    container.read(terminalControllerProvider.notifier).activate(3);
    await pumpEventQueue();
    expect(page.sessions.keys, containsAll([3, 5]));
    expect(page.sessions[3]!.written.toString(), isEmpty);
    expect(page.activeId, 3);

    // A new session takes the next id, beside them.
    await container.read(terminalControllerProvider.notifier).newSession();
    await pumpEventQueue();
    expect(container.read(terminalControllerProvider).tabs.last.sessionId, 10);

    // Closing the tombstone forgets it in the host.
    await container.read(terminalControllerProvider.notifier).close(3);
    await pumpEventQueue();
    expect(service.removed, [3]);
  });

  test('a host with nothing to restore leaves the panel empty', () async {
    final container = containerFor(service);
    container.read(terminalControllerProvider);
    await pumpEventQueue();
    expect(container.read(terminalControllerProvider).tabs, isEmpty);
    expect(surfaces.single.loads, 0, reason: 'the page waits for a session');
  });

  test('memory pressure lets hidden views go; showing one draws it again', () async {
    final container = containerFor(service);
    final controller = container.read(terminalControllerProvider.notifier);
    await controller.newSession();
    await pumpEventQueue();
    await controller.newSession();
    await pumpEventQueue();
    final page = surfaces.single;
    service.emitOutput(10, text: 'first\n');
    await pumpEventQueue();
    expect(container.read(terminalControllerProvider).activeId, 11);

    controller.releaseHiddenViews();
    await pumpEventQueue();
    expect(service.detached, [10]);
    expect(page.sessions.keys, [11], reason: 'only the shown view stays');

    // Output while let go stays in the host.
    service.buffers[10] = Uint8List.fromList(utf8.encode('first\nsecond\n'));
    service.emitOutput(10, text: 'second\n');
    await pumpEventQueue();
    controller.activate(10);
    await pumpEventQueue();
    expect(page.sessions[10]!.written.toString(), 'first\nsecond\n');
    expect(page.activeId, 10);
  });

  test('the background lets every view go; the return draws the shown one '
      'again', () async {
    final container = containerFor(service);
    final controller = container.read(terminalControllerProvider.notifier);
    await controller.newSession();
    await pumpEventQueue();
    await controller.newSession();
    await pumpEventQueue();
    final page = surfaces.single;
    service.emitOutput(11, text: 'shown\n');
    await pumpEventQueue();
    expect(page.sessions[11]!.written.toString(), 'shown\n');

    controller.releaseAllViews();
    await pumpEventQueue();
    expect(service.detached, [10, 11]);
    expect(page.sessions, isEmpty, reason: 'no view waits for the page');

    // What the shown session printed meanwhile waits in the host.
    service.buffers[11] = Uint8List.fromList(
      utf8.encode('shown\nwhile away\n'),
    );
    service.emitOutput(11, text: 'while away\n');
    await pumpEventQueue();
    controller.showAgain();
    await pumpEventQueue();
    expect(page.sessions.keys, [11]);
    expect(page.sessions[11]!.written.toString(), 'shown\nwhile away\n');
    expect(page.activeId, 11);

    // The other one's view opens with its tab.
    controller.activate(10);
    await pumpEventQueue();
    expect(page.sessions.keys, containsAll([10, 11]));
    expect(page.activeId, 10);
  });
}
