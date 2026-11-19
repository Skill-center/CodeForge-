/// Run (Phase 5 W4, gate G4's widget part): Run Current File and Run
/// Project start a terminal session in the project's folder with the
/// file's program; unsaved changes are saved first unless that is turned
/// off; the status chips follow the session (running, exit N, signal);
/// Stop ends it. The sessions are scripted
/// (test/support/scripted_terminal_service.dart), the page too.
library;

import 'dart:async';

import 'package:codeforge/application/commands.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/run/run_controller.dart';
import 'package:codeforge/application/runtime_controller.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/design_system/components/buttons.dart';
import 'package:codeforge/design_system/components/feedback.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/runtime/runtime_service.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_runtime_service.dart';
import '../support/scripted_terminal_service.dart';
import 'test_harness.dart';

final class _Run {
  _Run(this.harness, this.service);

  final TestHarness harness;
  final ScriptedTerminalService service;
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkbenchScreen)),
  listen: false,
);

Finder _key(String key) => find.byKey(ValueKey(key));

/// The workbench with the Run panel showing and the runtime ready, and
/// [open] open in the editor when given.
Future<_Run> _pump(
  WidgetTester tester, {
  AppSettings settings = const AppSettings(welcomeSeen: true),
  FakeRuntimeService? runtime,
  String? open,
}) async {
  setSurface(tester, 1280, 800);
  final service = ScriptedTerminalService();
  addTearDown(service.dispose);
  final harness = TestHarness(
    settings: settings,
    shell: const ShellState(
      lastRoute: '/workspace',
      activity: ShellActivity.run,
    ),
    terminal: service,
    runtime: runtime,
  );
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  if (open != null) {
    unawaited(
      _container(tester).read(documentControllerProvider.notifier).open(open),
    );
    await tester.pumpAndSettle();
  }
  return _Run(harness, service);
}

String _chip(WidgetTester tester, String key) =>
    tester.widget<CfStatusChip>(_key(key)).label;

void _runCommand(WidgetTester tester, String id) {
  final commands = _container(tester).read(commandRegistryProvider).commands;
  commands.firstWhere((c) => c.id == id).onExecute();
}

void main() {
  testWidgets('Run runs the open file with its program, in the project', (
    tester,
  ) async {
    final run = await _pump(tester, open: 'main.js');
    expect(_container(tester).read(runtimeControllerProvider).usable, isTrue);
    expect(_key('run_empty'), findsOneWidget);
    expect(find.text('Run main.js'), findsOneWidget);
    expect(_key('status_run'), findsNothing);

    await tester.tap(_key('run_current_file'));
    await tester.pumpAndSettle();
    final spec = run.service.specs.single;
    expect(spec.project, demoProjectFolder);
    expect(spec.program, 'node');
    expect(spec.arguments, ['main.js']);
    expect(spec.label, 'main.js');
    // Its terminal opened, named for it, and shows.
    expect(_key('terminal_tab_1'), findsOneWidget);
    expect(run.harness.terminalSurfaces.single.activeId, 1);
    expect(_chip(tester, 'run_status:1'), 'Running');
    expect(_chip(tester, 'status_run'), 'main.js: running');
    expect(_key('run_stop:1'), findsOneWidget);

    run.service.exit(1, code: 0);
    await tester.pumpAndSettle();
    expect(_chip(tester, 'run_status:1'), 'Exit 0');
    expect(_chip(tester, 'status_run'), 'main.js: exit 0');
    expect(_key('run_stop:1'), findsNothing);

    // Run again: a second session, newest first.
    await tester.tap(_key('run_again:1'));
    await tester.pumpAndSettle();
    expect(run.service.specs, hasLength(2));
    expect(run.service.specs.last.arguments, ['main.js']);
    expect(_chip(tester, 'run_status:2'), 'Running');
    run.service.exit(2, code: 3);
    await tester.pumpAndSettle();
    expect(_chip(tester, 'run_status:2'), 'Exit 3');
    expect(_chip(tester, 'status_run'), 'main.js: exit 3');
    expect(_chip(tester, 'run_status:1'), 'Exit 0');
  });

  testWidgets('each language gets its program; others are not offered', (
    tester,
  ) async {
    final run = await _pump(tester, open: 'app.py');
    await tester.tap(_key('run_current_file'));
    await tester.pumpAndSettle();
    expect(run.service.specs.single.program, 'python');
    expect(run.service.specs.single.arguments, ['app.py']);

    run.harness.files.putText('tools/build.sh', 'echo built\n');
    unawaited(
      _container(
        tester,
      ).read(documentControllerProvider.notifier).open('tools/build.sh'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Run build.sh'), findsOneWidget);
    _runCommand(tester, 'run.file');
    await tester.pumpAndSettle();
    expect(run.service.specs.last.program, 'bash');
    expect(run.service.specs.last.arguments, ['tools/build.sh']);
    expect(_chip(tester, 'status_language'), 'shell');

    unawaited(
      _container(
        tester,
      ).read(documentControllerProvider.notifier).open('README.md'),
    );
    await tester.pumpAndSettle();
    final button = tester.widget<CfButton>(_key('run_current_file'));
    expect(button.label, 'Run current file');
    expect(button.onPressed, isNull);
    _runCommand(tester, 'run.file');
    await tester.pumpAndSettle();
    expect(find.text(notRunnableMessage), findsOneWidget);
    expect(run.service.specs, hasLength(2));
  });

  testWidgets('unsaved changes are saved before a run', (tester) async {
    final run = await _pump(tester, open: 'main.js');
    run.harness.editorSurface.typeText('// edited\n');
    await tester.pumpAndSettle();
    final documents = _container(tester).read(documentControllerProvider);
    expect(documents.documents['main.js']!.dirty, isTrue);
    final writes = run.harness.files.writes.length;

    await tester.tap(_key('run_current_file'));
    await tester.pumpAndSettle();
    expect(run.harness.files.writes.sublist(writes), ['main.js']);
    expect(
      _container(
        tester,
      ).read(documentControllerProvider).documents['main.js']!.dirty,
      isFalse,
    );
    expect(run.service.specs, hasLength(1));
  });

  testWidgets('…unless that is turned off', (tester) async {
    final run = await _pump(
      tester,
      settings: const AppSettings(welcomeSeen: true, saveBeforeRun: false),
      open: 'main.js',
    );
    run.harness.editorSurface.typeText('// edited\n');
    await tester.pumpAndSettle();
    final writes = run.harness.files.writes.length;

    await tester.tap(_key('run_current_file'));
    await tester.pumpAndSettle();
    expect(run.harness.files.writes.length, writes);
    expect(
      _container(
        tester,
      ).read(documentControllerProvider).documents['main.js']!.dirty,
      isTrue,
    );
    expect(run.service.specs, hasLength(1));
  });

  testWidgets('Settings turns saving before a run off and on', (tester) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/settings'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    final tile = _key('settings_save_before_run');
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(harness.settingsStore.load().saveBeforeRun, isTrue);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(harness.settingsStore.load().saveBeforeRun, isFalse);
    await tester.tap(find.descendant(of: tile, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(harness.settingsStore.load().saveBeforeRun, isTrue);
  });

  testWidgets('Stop ends the run, and its chip says how it ended', (
    tester,
  ) async {
    final run = await _pump(tester, open: 'main.js');
    await tester.tap(_key('run_current_file'));
    await tester.pumpAndSettle();
    await tester.tap(_key('run_stop:1'));
    await tester.pumpAndSettle();
    expect(run.service.ended, [1]);
    expect(_chip(tester, 'run_status:1'), 'Ended');
    // Its tab and output stay.
    expect(_key('terminal_tab_1'), findsOneWidget);

    // A run a signal ended says which.
    await tester.tap(_key('run_again:1'));
    await tester.pumpAndSettle();
    run.service.exit(2, code: null, signal: 9);
    await tester.pumpAndSettle();
    expect(_chip(tester, 'run_status:2'), 'Signal 9');
    expect(_chip(tester, 'status_run'), 'main.js: signal 9');

    // Stop from the palette stops the newest run still running.
    await tester.tap(_key('run_again:2'));
    await tester.pumpAndSettle();
    _runCommand(tester, 'run.stop');
    await tester.pumpAndSettle();
    expect(run.service.ended, [1, 3]);
  });

  testWidgets('Run Project offers the scripts of package.json, then main', (
    tester,
  ) async {
    final run = await _pump(tester);
    await tester.tap(_key('run_project'));
    await tester.pumpAndSettle();
    expect(_key('run_project_dialog'), findsOneWidget);
    // The demo's package.json has a start script; main.js is its entry.
    expect(_key('run_choice:npm run start'), findsOneWidget);
    expect(_key('run_choice:main.js'), findsOneWidget);
    await tester.tap(_key('run_choice:npm run start'));
    await tester.pumpAndSettle();
    final spec = run.service.specs.single;
    expect(spec.program, 'npm');
    expect(spec.arguments, ['run', 'start']);
    expect(spec.project, demoProjectFolder);
    expect(_chip(tester, 'status_run'), 'npm run start: running');
  });

  testWidgets('a project with nothing to run says so', (tester) async {
    final run = await _pump(tester);
    for (final path in ['main.js', 'app.py', 'package.json']) {
      run.harness.files.remove(path);
    }
    await tester.pumpAndSettle();
    await tester.tap(_key('run_project'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing to run here'), findsOneWidget);
    await tester.tap(_key('run_project_cancel'));
    await tester.pumpAndSettle();
    expect(run.service.specs, isEmpty);
  });

  testWidgets('Run waits for the runtime', (tester) async {
    final run = await _pump(
      tester,
      runtime: FakeRuntimeService(state: RuntimeState.notInstalled),
      open: 'main.js',
    );
    expect(_key('run_runtime_not_ready'), findsOneWidget);
    expect(tester.widget<CfButton>(_key('run_current_file')).onPressed, isNull);
    expect(tester.widget<CfButton>(_key('run_project')).onPressed, isNull);
    _runCommand(tester, 'run.file');
    await tester.pumpAndSettle();
    expect(find.text('The Linux runtime is not ready yet.'), findsOneWidget);
    expect(run.service.specs, isEmpty);
  });

  testWidgets('Ctrl+F5 runs the open file; the status chip opens Run', (
    tester,
  ) async {
    final run = await _pump(tester, open: 'main.js');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(run.service.specs.single.program, 'node');

    await tester.tap(_key('activity_explorer'));
    await tester.pumpAndSettle();
    expect(_key('run_current_file'), findsNothing);
    await tester.tap(_key('status_run'));
    await tester.pumpAndSettle();
    expect(_key('run_current_file'), findsOneWidget);
  });
}
