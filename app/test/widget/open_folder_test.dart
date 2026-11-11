/// Home's Open Folder (Phase 3 W2, gate G1): Android's picker opens a
/// folder from the device as the workspace; backing out stays home; a
/// folder that is gone or no longer granted says so, on Home and in the
/// explorer, without a crash. The picker and the folder are a fake storage
/// broker's.
library;

import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(harness.shellStore.load().folder, _folder);

    await tester.tap(find.byKey(const ValueKey('tree_hello.txt')));
    await tester.pumpAndSettle();
    expect(harness.editorSurface.documents.values.single.text, 'Hello from the gate\n');
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
    expect(harness.shellStore.load().folder, isNull);
    expect(find.byKey(const ValueKey('continue_folder')), findsNothing);
  });

  testWidgets('a folder that is gone says so on Home, without a crash', (
    tester,
  ) async {
    setSurface(tester, 412, 915);
    final broker = _broker()..granted.add(_uri);
    broker.trees[_uri]!.missing = true;
    final harness = TestHarness(
      broker: broker,
      shell: const ShellState(folder: _folder),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.text('Continue in cf-gate'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('continue_folder')));
    await tester.pumpAndSettle();
    expect(find.textContaining('"cf-gate" is missing'), findsOneWidget);
    expect(find.byKey(const ValueKey('explore_demo')), findsOneWidget);

    // The built-in project still opens.
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    expect(harness.shellStore.load().folder, isNull);
    // Past the snack bar's time on screen, so no timer outlives the test.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('after a restart, a lost grant shows in the explorer', (
    tester,
  ) async {
    setSurface(tester, 1280, 800);
    final broker = _broker(pickable: false);
    final harness = TestHarness(
      broker: broker,
      shell: const ShellState(lastRoute: '/workspace', folder: _folder),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('terminal_toggle')), findsOneWidget);
    expect(find.textContaining('no longer has access to "cf-gate"'), findsOneWidget);
    expect(find.byKey(const ValueKey('tree_hello.txt')), findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
  });
}
