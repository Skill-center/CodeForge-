/// Files that change outside the app, in the workbench (Phase 3 W5, gate
/// G4): a clean document reloads with a notice, unsaved changes get the
/// banner with its two choices, the explorer follows new and deleted
/// files, and what changed in the background shows when the app comes
/// back. The editor is the scripted page; changes are made to the
/// harness's in-memory files the way another program would make them.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/file_watch_controller.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_harness.dart';

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkbenchScreen)),
  listen: false,
);

DocumentsState _state(WidgetTester tester) =>
    _container(tester).read(documentControllerProvider);

Future<TestHarness> _pumpWorkbench(WidgetTester tester) async {
  setSurface(tester, 1280, 800);
  final harness = TestHarness(
    shell: const ShellState(lastRoute: '/workspace'),
  );
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  return harness;
}

/// What the page shows for [path].
String? _pageText(WidgetTester tester, TestHarness harness, String path) {
  final doc = _state(tester).documents[path];
  return doc == null ? null : harness.editorSurface.documents[doc.docId]?.text;
}

/// Lets the watcher's batch run, and what it started finish.
Future<void> _afterBatch(WidgetTester tester) async {
  await tester.pump(
    const FileWatchSettings().batch + const Duration(milliseconds: 50),
  );
  await tester.pumpAndSettle();
}

/// The app reaches [state] the way Android tells it: a message on the
/// lifecycle channel, from which Flutter makes the states in between.
Future<void> _lifecycle(WidgetTester tester, AppLifecycleState state) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.lifecycle.name,
    SystemChannels.lifecycle.codec.encodeMessage(state.toString()),
    (_) {},
  );
  await tester.pump();
}

Finder _inBanner(String label) => find.descendant(
  of: find.byKey(const ValueKey('disk_conflict_notice')),
  matching: find.text(label),
);

void main() {
  testWidgets('a clean document reloads, with a notice', (tester) async {
    final harness = await _pumpWorkbench(tester);
    expect(_state(tester).activePath, 'main.js');
    harness.files.putText('main.js', '// rewritten by a formatter\n');
    await _afterBatch(tester);
    expect(_pageText(tester, harness, 'main.js'), '// rewritten by a formatter\n');
    expect(_state(tester).documents['main.js']!.dirty, isFalse);
    expect(
      find.text('main.js changed on disk and was reloaded.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('disk_conflict_notice')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('unsaved changes stay, and the banner offers both versions', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);
    final page = harness.editorSurface;
    page.typeText('// mine\n');
    await tester.pumpAndSettle();
    final mine = _pageText(tester, harness, 'main.js');

    harness.files.putText('main.js', 'theirs\n');
    await _afterBatch(tester);
    expect(find.byKey(const ValueKey('disk_conflict_notice')), findsOneWidget);
    expect(_pageText(tester, harness, 'main.js'), mine);
    expect(
      _state(tester).documents['main.js']!.conflict,
      DocumentConflict.changedWhileOpen,
    );
    // Not the dialog restored changes get: typing goes on.
    expect(find.byKey(const ValueKey('conflict_dialog')), findsNothing);

    await tester.tap(_inBanner('Keep mine'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('disk_conflict_notice')), findsNothing);
    expect(_state(tester).documents['main.js']!.conflict, isNull);
    expect(_state(tester).documents['main.js']!.dirty, isTrue);
    expect(_pageText(tester, harness, 'main.js'), mine);

    harness.files.putText('main.js', 'theirs again\n');
    await _afterBatch(tester);
    await tester.tap(_inBanner('Use the file'));
    await tester.pumpAndSettle();
    // Dropping unsaved text asks first.
    expect(find.byKey(const ValueKey('confirm_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm_ok')));
    await tester.pumpAndSettle();
    expect(_pageText(tester, harness, 'main.js'), 'theirs again\n');
    expect(_state(tester).documents['main.js']!.dirty, isFalse);
    expect(find.byKey(const ValueKey('disk_conflict_notice')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('saving over a file that changed asks first', (tester) async {
    final harness = await _pumpWorkbench(tester);
    harness.editorSurface.typeText('// mine\n');
    await tester.pumpAndSettle();
    final mine = _pageText(tester, harness, 'main.js');
    harness.files.putText('main.js', 'theirs\n');
    await _afterBatch(tester);
    await tester.tap(find.byKey(const ValueKey('editor_save')));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite main.js?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm_ok')));
    await tester.pumpAndSettle();
    expect(harness.files.textOf('main.js'), mine);
    expect(find.byKey(const ValueKey('disk_conflict_notice')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('new and deleted files reach the explorer; a clean tab closes', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);
    harness.files.putText('aaa-fresh.txt', 'new\n');
    await _afterBatch(tester);
    expect(find.byKey(const ValueKey('tree_aaa-fresh.txt')), findsOneWidget);

    harness.files.remove('aaa-fresh.txt');
    await _afterBatch(tester);
    expect(find.byKey(const ValueKey('tree_aaa-fresh.txt')), findsNothing);

    harness.files.remove('main.js');
    await _afterBatch(tester);
    expect(_state(tester).isOpen('main.js'), isFalse);
    expect(find.text('main.js was deleted on disk, so its tab closed.'), findsOneWidget);
    expect(find.byKey(const ValueKey('tree_main.js')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('what changed in the background shows on coming back', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);
    final before = _pageText(tester, harness, 'main.js');
    await _lifecycle(tester, AppLifecycleState.paused);
    harness.files.putText('main.js', '// changed while away\n');
    await tester.pump(const Duration(seconds: 1));
    expect(_pageText(tester, harness, 'main.js'), before);
    await _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(_pageText(tester, harness, 'main.js'), '// changed while away\n');
    await tester.pump(const Duration(seconds: 5));
  });
}
