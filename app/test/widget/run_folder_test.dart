/// Run in a folder from shared storage (Phase 5 W4, ADR-0013, gate G4's
/// widget part): the run happens in the folder's copy, brought up to date
/// first, which the panel shows as it goes, with Cancel; what the copy left
/// out is said; the files runs made are listed and exported to the folder
/// on request; the explorer imports the folder as a project. The broker,
/// its copies and the sessions are fakes
/// (test/support/fake_storage_broker.dart,
/// test/support/scripted_terminal_service.dart).
library;

import 'dart:async';
import 'dart:convert';

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/files/storage_broker.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_storage_broker.dart';
import '../support/scripted_terminal_service.dart';
import 'test_harness.dart';

const _uri =
    'content://com.android.externalstorage.documents/tree/primary%3Asite';
const _folder = FolderLocation(treeUri: _uri, name: 'site');

final class _Folder {
  _Folder(this.harness, this.broker, this.service);

  final TestHarness harness;
  final FakeStorageBroker broker;
  final ScriptedTerminalService service;
}

Finder _key(String key) => find.byKey(ValueKey(key));

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkbenchScreen)),
  listen: false,
);

/// The workbench on the folder `site`, with [activity] showing and
/// main.js open.
Future<_Folder> _pump(
  WidgetTester tester, {
  ShellActivity activity = ShellActivity.run,
}) async {
  setSurface(tester, 1280, 800);
  final broker = FakeStorageBroker()
    ..addTree(
      _uri,
      'site',
      files: {'main.js': 'console.log(1)\n', '.git/HEAD': 'ref\n'},
    );
  final service = ScriptedTerminalService();
  addTearDown(service.dispose);
  final harness = TestHarness(
    broker: broker,
    shell: ShellState(
      lastRoute: '/workspace',
      activity: activity,
      workspace: _folder,
    ),
    terminal: service,
  );
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  if (activity == ShellActivity.run) {
    unawaited(
      _container(
        tester,
      ).read(documentControllerProvider.notifier).open('main.js'),
    );
    await tester.pumpAndSettle();
  }
  return _Folder(harness, broker, service);
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(_key(key)).data!;

void main() {
  testWidgets('a run in a folder happens in its copy, brought up to date', (
    tester,
  ) async {
    final run = await _pump(tester);
    await tester.tap(_key('run_current_file'));
    await tester.pumpAndSettle();
    expect(run.broker.synced, [_folder.id]);
    final spec = run.service.specs.single;
    expect(spec.copy, _folder.id);
    expect(spec.project, isNull);
    expect(spec.program, 'node');
    expect(spec.arguments, ['main.js']);
    expect(
      _text(tester, 'run_copy:1'),
      'In the folder’s copy: 1 file copied (15 B), in 0.0 s',
    );
    // git's files stay out of the copy.
    expect(run.broker.copies[_folder.id]!.keys, ['main.js']);

    run.service.exit(1);
    await tester.pumpAndSettle();
    await tester.tap(_key('run_again:1'));
    await tester.pumpAndSettle();
    expect(run.broker.synced, [_folder.id, _folder.id]);
    expect(
      _text(tester, 'run_copy:2'),
      'In the folder’s copy: nothing new to copy, 1 unchanged, in 0.0 s',
    );
  });

  testWidgets('the files runs made are exported to the folder on request', (
    tester,
  ) async {
    final run = await _pump(tester);
    await tester.tap(_key('run_current_file'));
    await tester.pumpAndSettle();
    // The run writes a report, and changes main.js.
    run.broker.copies[_folder.id]!['out/report.txt'] = utf8.encode(
      'report\n',
    );
    run.broker.copies[_folder.id]!['main.js'] = utf8.encode('changed\n');
    await tester.tap(_key('run_files:1'));
    await tester.pumpAndSettle();
    expect(_key('run_files_dialog'), findsOneWidget);
    expect(_key('run_file:out/report.txt'), findsOneWidget);
    expect(_key('run_file:main.js'), findsOneWidget);
    expect(find.text('New · 7 B'), findsOneWidget);
    expect(find.text('Changed · 8 B'), findsOneWidget);
    // Only the report goes.
    await tester.tap(_key('run_file:main.js'));
    await tester.pumpAndSettle();
    await tester.tap(_key('run_export'));
    await tester.pumpAndSettle();
    final tree = run.broker.trees[_uri]!;
    expect(tree.text('out/report.txt'), 'report\n');
    expect(tree.text('main.js'), 'console.log(1)\n');
    expect(find.text('Exported 1 file to the folder.'), findsOneWidget);

    // What was exported is no longer a run's file.
    await tester.tap(_key('run_files:1'));
    await tester.pumpAndSettle();
    expect(_key('run_file:out/report.txt'), findsNothing);
    expect(_key('run_file:main.js'), findsOneWidget);
    await tester.tap(_key('run_files_cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('the copy shows as it goes, and Cancel runs nothing', (
    tester,
  ) async {
    final run = await _pump(tester);
    final gate = run.broker.syncGate = Completer<void>();
    await tester.tap(_key('run_current_file'));
    await tester.pump();
    await tester.pump();
    expect(_key('run_copying'), findsOneWidget);
    expect(
      _text(tester, 'run_copying_text'),
      'Copying the folder for the run…',
    );
    run.broker.emitProgress(_folder.id, files: 12, bytes: 2048);
    await tester.pump();
    expect(
      _text(tester, 'run_copying_text'),
      'Copying the folder for the run: 12 files, 2.0 KB',
    );
    await tester.tap(_key('run_copy_cancel'));
    await tester.pump();
    expect(run.broker.calls, contains('cancelCopy'));
    run.broker.nextSummary = const CopySummary(
      files: 0,
      bytes: 0,
      stopped: true,
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(_key('run_copying'), findsNothing);
    expect(run.service.specs, isEmpty);
    expect(find.text('The copy was cancelled, so nothing ran.'), findsOneWidget);
  });

  testWidgets('what the copy left out is said', (tester) async {
    final run = await _pump(tester);
    run.broker.nextSummary = const CopySummary(
      files: 1,
      bytes: 15,
      copied: 1,
      bytesCopied: 15,
      leftOutLarge: 2,
      unreadable: 1,
    );
    await tester.tap(_key('run_current_file'));
    await tester.pumpAndSettle();
    expect(run.service.specs, hasLength(1));
    expect(
      find.text(
        'The copy left out 2 files over 64 MB, 1 that could not be read. '
        'Import the folder as a project to run it whole.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the explorer imports the folder as a project, which opens', (
    tester,
  ) async {
    final run = await _pump(tester, activity: ShellActivity.explorer);
    run.harness.projects.add('site');
    await tester.tap(_key('explorer_import'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(_key('project_name_field'));
    expect(field.controller!.text, 'site-2', reason: 'site is taken');
    await tester.tap(_key('project_name_confirm'));
    await tester.pumpAndSettle();
    expect(run.broker.calls, contains('importFolder'));
    final workspace = run.harness.shellStore.load().workspace;
    expect((workspace! as ProjectLocation).folder, 'site-2');
    expect(
      run.harness.projects.projects['site-2']!.textOf('main.js'),
      'console.log(1)\n',
    );
    // A project has no import of its own.
    expect(_key('explorer_import'), findsNothing);
  });

  test('a free name for an imported folder', () {
    expect(importNameFor('site'), 'site');
    expect(importNameFor('site', taken: ['Site']), 'site-2');
    expect(importNameFor('site', taken: ['site', 'site-2']), 'site-3');
    expect(importNameFor('.config'), 'config');
    expect(importNameFor('a/b\\c'), 'a_b_c');
    expect(importNameFor('...'), 'imported');
    expect(importNameFor(demoProjectFolder), '$demoProjectFolder-2');
  });
}
