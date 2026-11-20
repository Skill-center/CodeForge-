/// What a run's output leads to (Phase 5 W4, gate G4's widget part): a
/// `file:line` tapped in a terminal opens the file at that line, relative
/// paths and the project's absolute ones (both of Android's spellings);
/// one outside the workspace says so. A native build failing for want of a
/// compiler puts a banner on its terminal, once, until dismissed. The page
/// and the sessions are scripted.
library;

import 'dart:async';

import 'package:codeforge/application/terminal/terminal_controller.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/terminal/native_addons.dart';
import 'package:codeforge/features/workbench/panels/terminal_pane.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/scripted_terminal_service.dart';
import 'test_harness.dart';

Finder _key(String key) => find.byKey(ValueKey(key));

Future<({TestHarness harness, ScriptedTerminalService service})> _pump(
  WidgetTester tester,
) async {
  setSurface(tester, 1280, 800);
  final service = ScriptedTerminalService();
  addTearDown(service.dispose);
  final harness = TestHarness(
    shell: const ShellState(
      lastRoute: '/workspace',
      terminalStop: TerminalStop.half,
    ),
    terminal: service,
  );
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(TerminalPane)),
  );
  unawaited(container.read(terminalControllerProvider.notifier).newSession());
  await tester.pumpAndSettle();
  return (harness: harness, service: service);
}

void main() {
  testWidgets('a file:line in a terminal opens the file at that line', (
    tester,
  ) async {
    final (:harness, :service) = await _pump(tester);
    final page = harness.terminalSurfaces.single;
    expect(service.specs.single.project, demoProjectFolder);

    page.emit('session.link', {'sessionId': 1, 'text': 'main.js:3:5'});
    await tester.pumpAndSettle();
    expect(harness.editorSurface.documents.values.single.text, contains('demo'));
    expect(harness.editorSurface.gotoLines.last, (line: 3, column: 5));

    // An absolute path in the project, as node's realpath prints it.
    page.emit('session.link', {
      'sessionId': 1,
      'text': '/data/data/dev.codeforge.app/files/workspaces/'
          '$demoProjectFolder/utils.js:2',
    });
    await tester.pumpAndSettle();
    expect(harness.editorSurface.gotoLines.last, (line: 2, column: null));
    expect(find.text('utils.js'), findsWidgets);

    page.emit('session.link', {'sessionId': 1, 'text': '/etc/passwd:1'});
    await tester.pumpAndSettle();
    expect(find.text('/etc/passwd is not in this workspace.'), findsOneWidget);
  });

  testWidgets('a native build that fails says why, once, until dismissed', (
    tester,
  ) async {
    final (:harness, :service) = await _pump(tester);
    expect(_key('terminal_native_addon'), findsNothing);
    service.emitOutput(1, text: 'npm error gyp ERR! stack Error: not found: ');
    service.emitOutput(1, text: 'make\r\n');
    await tester.pumpAndSettle();
    expect(_key('terminal_native_addon'), findsOneWidget);
    expect(
      find.text(nativeAddonMessage(NativeAddonKind.npm)),
      findsOneWidget,
    );
    // The output still reached the terminal.
    expect(
      harness.terminalSurfaces.single.sessions[1]!.written.toString(),
      contains('gyp ERR!'),
    );

    await tester.tap(_key('terminal_native_addon_dismiss'));
    await tester.pumpAndSettle();
    expect(_key('terminal_native_addon'), findsNothing);
    service.emitOutput(1, text: 'gyp ERR! again\r\n');
    await tester.pumpAndSettle();
    expect(_key('terminal_native_addon'), findsNothing);
  });
}
