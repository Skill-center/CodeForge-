/// Home's Open Folder (Phase 3 W2, gate G1): Android's picker opens a
/// folder from the device as the workspace; backing out stays home; a
/// folder that is gone or no longer granted says so on Home, in its entry
/// of the recents (Phase 3 W3), without a crash, and a cold start into it
/// lands on Home. The picker and the folder are a fake storage broker's.
library;

import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_storage_broker.dart';
import 'test_harness.dart';

const _uri =
    'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2Fcf-gate';
const _folder = FolderLocation(treeUri: _uri, name: 'cf-gate');

FakeStorageBroker _broker({bool pickable = true}) {
  final broker = FakeStorageBroker()
    ..addTree(
      _uri,
      'cf-gate',
      files: {'hello.txt': 'Hello from the gate\n', 'src/main.js': 'run();\n'},
      grant: false,
    );
  if (pickable) {
    broker.pickAnswer = _uri;
  }
  return broker;
}

void main() {
  testWidgets('Open Folder opens the picked folder in the workbench', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final broker = _broker();
    final harness = TestHarness(broker: broker);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open_folder')));
    await tester.pumpAndSettle();

    expect(broker.calls.first, 'pickFolder');
    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    expect(find.text('cf-gate'), findsWidgets);
    expect(find.byKey(const ValueKey('tree_hello.txt')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree_src')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree_main.js')), findsNothing);
    expect(harness.shellStore.load().workspace, _folder);

    await tester.tap(find.byKey(const ValueKey('tree_hello.txt')));
    await tester.pumpAndSettle();
    expect(
      harness.editorSurface.documents.values.single.text,
      'Hello from the gate\n',
    );
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('backing out of the picker stays home', (tester) async {
    setSurface(tester, 412, 915);
    final broker = _broker(pickable: false);
    final harness = TestHarness(broker: broker);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open_folder')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('explore_demo')), findsOneWidget);
    expect(harness.shellStore.load().workspace, isNull);
    expect(find.byKey(ValueKey('recent_${_folder.id}')), findsNothing);
  });

  testWidgets('a folder that is gone says so on Home, without a crash', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final broker = _broker()..granted.add(_uri);
    broker.trees[_uri]!.missing = true;
    final harness = TestHarness(
      broker: broker,
      shell: const ShellState(workspace: _folder),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    final entry = find.byKey(ValueKey('recent_${_folder.id}'));
    await tester.scrollUntilVisible(entry, 200);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: entry, matching: find.text('folder missing')),
      findsOneWidget,
    );
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.textContaining('"cf-gate" is missing'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.byKey(const ValueKey('explore_demo')), findsOneWidget);
    // Still the folder: nothing was left for a workspace that is gone.
    expect(harness.shellStore.load().workspace, _folder);

    // The built-in project still opens.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('explore_demo')),
      -200,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    expect(harness.shellStore.load().workspace, const DemoProjectLocation());
    // Past the snack bar's time on screen, so no timer outlives the test.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('after a restart, a lost grant lands on Home, saying so', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final broker = _broker(pickable: false);
    final harness = TestHarness(
      broker: broker,
      shell: const ShellState(lastRoute: '/workspace', workspace: _folder),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('new_project')), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal_toggle')), findsNothing);
    expect(
      find.textContaining('no longer has access to "cf-gate"'),
      findsOneWidget,
    );
    final entry = find.byKey(ValueKey('recent_${_folder.id}'));
    await tester.scrollUntilVisible(entry, 200);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: entry, matching: find.text('access lost')),
      findsOneWidget,
    );
    // Past the snack bar's time on screen, so no timer outlives the test.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
