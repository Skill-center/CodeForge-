/// Go to File (Phase 3 W4): Ctrl+P, or *Go to File…* in the command
/// palette, finds a file by fuzzy matching over the workspace's index and
/// opens it. Hidden files follow the explorer's setting; the line under the
/// results says how many files were searched.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/file_index.dart';
import 'package:codeforge/application/settings_controller.dart';
import 'package:codeforge/features/palette/go_to_file.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/settings/settings_model.dart';
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

DocumentsState _documents(WidgetTester tester) =>
    _container(tester).read(documentControllerProvider);

final Finder _input = find.byKey(const ValueKey('go_to_file_input'));

Finder _row(String path) => find.byKey(ValueKey('go_to_file_$path'));

String _status(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('go_to_file_status'))).data!;

Future<TestHarness> _pumpWorkbench(
  WidgetTester tester, {
  AppSettings settings = const AppSettings(welcomeSeen: true),
  void Function(TestHarness harness)? before,
}) async {
  setSurface(tester, 1280, 800);
  final harness = TestHarness(
    settings: settings,
    shell: const ShellState(lastRoute: '/workspace'),
  );
  before?.call(harness);
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _ctrlP(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Ctrl+P finds a file and Enter opens it', (tester) async {
    await _pumpWorkbench(tester);
    await _ctrlP(tester);
    expect(_input, findsOneWidget);
    // The demo project's eight files, found top folders first.
    expect(_status(tester), '8 files. .git and node_modules are skipped.');
    expect(_row('main.js'), findsOneWidget);

    await tester.enterText(_input, 'grt');
    await tester.pumpAndSettle();
    expect(_row('src/greeting.dart'), findsOneWidget);
    expect(_row('main.js'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_input, findsNothing);
    expect(_documents(tester).activePath, 'src/greeting.dart');
  });

  testWidgets('the arrow keys choose among the matches', (tester) async {
    await _pumpWorkbench(tester);
    await _ctrlP(tester);
    await tester.enterText(_input, 'js');
    await tester.pumpAndSettle();
    // Three names have "js" right after a dot: the shortest first.
    final first = tester.getTopLeft(_row('main.js')).dy;
    final second = tester.getTopLeft(_row('utils.js')).dy;
    expect(first, lessThan(second));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_documents(tester).activePath, 'utils.js');
  });

  testWidgets('a tap opens a file, and nothing matching says so', (
    tester,
  ) async {
    await _pumpWorkbench(tester);
    await _ctrlP(tester);
    await tester.enterText(_input, 'qqq');
    await tester.pumpAndSettle();
    expect(find.text('No matching files'), findsOneWidget);

    await tester.enterText(_input, 'notes');
    await tester.pumpAndSettle();
    await tester.tap(_row('src/notes.txt'));
    await tester.pumpAndSettle();
    expect(_documents(tester).activePath, 'src/notes.txt');
  });

  testWidgets('the command palette opens it too', (tester) async {
    await _pumpWorkbench(tester);
    await tester.tap(find.byKey(const ValueKey('palette_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('palette_input')), 'go');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('palette_file.goTo')));
    await tester.pumpAndSettle();
    expect(_input, findsOneWidget);
    expect(find.byKey(const ValueKey('palette_input')), findsNothing);
  });

  testWidgets('hidden files follow the explorer setting', (tester) async {
    await _pumpWorkbench(tester);
    await _ctrlP(tester);
    await tester.enterText(_input, 'gitignore');
    await tester.pumpAndSettle();
    expect(_row('.gitignore'), findsNothing);

    await _container(
      tester,
    ).read(settingsControllerProvider.notifier).setShowHiddenFiles(true);
    await tester.pumpAndSettle();
    expect(_row('.gitignore'), findsOneWidget);
  });

  testWidgets('skips node_modules and .git', (tester) async {
    await _pumpWorkbench(
      tester,
      settings: const AppSettings(welcomeSeen: true, showHiddenFiles: true),
      before: (harness) {
        harness.files
          ..putText('node_modules/left/index.js', '')
          ..putText('.git/HEAD', '')
          ..putText('web/index.js', '');
      },
    );
    await _ctrlP(tester);
    await tester.enterText(_input, 'index');
    await tester.pumpAndSettle();
    expect(_row('web/index.js'), findsOneWidget);
    expect(_row('node_modules/left/index.js'), findsNothing);
    await tester.enterText(_input, 'head');
    await tester.pumpAndSettle();
    expect(_row('.git/HEAD'), findsNothing);
  });

  testWidgets('a file gone since it was found is reported and dropped', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);
    await _ctrlP(tester);
    harness.files.remove('src/notes.txt');
    await tester.enterText(_input, 'notes');
    await tester.pumpAndSettle();
    await tester.tap(_row('src/notes.txt'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(_documents(tester).activePath, isNot('src/notes.txt'));
    await _container(tester).read(fileIndexProvider.notifier).settled;
    expect(
      _container(tester).read(fileIndexProvider).files.map((f) => f.path),
      isNot(contains('src/notes.txt')),
    );
  });

  test('says how far the index got', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(1000), '1,000');
    expect(formatCount(50000), '50,000');
    expect(formatCount(1234567), '1,234,567');
    expect(
      goToFileStatus(const FileIndexState(status: FileIndexStatus.building)),
      'Finding files… 0 so far',
    );
    expect(
      goToFileStatus(
        const FileIndexState(status: FileIndexStatus.ready, truncated: true),
      ),
      'Only the first 50,000 files are searched, so some can’t be found '
      'here. .git and node_modules are skipped.',
    );
  });
}
