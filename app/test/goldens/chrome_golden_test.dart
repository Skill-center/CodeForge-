/// Goldens of the Phase 2 workbench chrome that no screen golden shows
/// (PHASE_2_PLAN W7, "goldens for the new chrome"): find and replace with a
/// query, the large-file notice with its status chip, and a dialog beside
/// the soft keyboard on a short phone in landscape. Baselines are generated
/// on the CI Linux runner via the [bootstrap] flow, like the screen goldens.
@Tags(['golden'])
library;

import 'dart:async';

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/find_controller.dart';
import 'package:codeforge/core/editor/large_files.dart';
import 'package:codeforge/features/workbench/editor_dialogs.dart';
import 'package:codeforge/features/workbench/panels/editor_pane.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../widget/test_harness.dart';

const String _line = "console.log(greet('CodeForge'));\n";

/// Just over the plain-text threshold, so a .js file opens as plain text.
final String _bigScript = _line * (plainTextAboveChars ~/ _line.length + 1);

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(EditorPane)),
  listen: false,
);

/// The workspace with the terminal at [stop]; [bigFile], when given, holds
/// a script just over the plain-text threshold.
Future<void> _pumpWorkspace(
  WidgetTester tester,
  TerminalStop stop, {
  String? bigFile,
}) async {
  final harness = TestHarness(
    shell: ShellState(lastRoute: '/workspace', terminalStop: stop),
  );
  if (bigFile != null) {
    harness.files.putText(bigFile, _bigScript);
  }
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
}

Future<void> _expectGolden(WidgetTester tester, String file) async {
  expect(tester.takeException(), isNull);
  await expectLater(find.byType(MaterialApp), matchesGoldenFile(file));
  // Let the shell's debounced persistence timer fire before teardown.
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('find and replace 412x915 dark', (tester) async {
    setSurface(tester, 412, 915);
    await _pumpWorkspace(tester, TerminalStop.half);
    final search = _container(tester).read(findControllerProvider.notifier);
    unawaited(search.open(replace: true));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('find_query')), 'lang');
    await tester.pumpAndSettle();
    await _expectGolden(tester, 'chrome/find_replace_412x915_dark.png');
  });

  testWidgets('large-file notice 412x915 dark', (tester) async {
    setSurface(tester, 412, 915);
    await _pumpWorkspace(tester, TerminalStop.closed, bigFile: 'big.js');
    final container = _container(tester);
    final documents = container.read(documentControllerProvider.notifier);
    unawaited(documents.open('big.js'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('large_file_notice')), findsOneWidget);
    await _expectGolden(tester, 'chrome/large_file_412x915_dark.png');
  });

  testWidgets('go to line beside the keyboard 800x360 dark', (tester) async {
    setSurface(tester, 800, 360);
    // The keyboard of keyboard_insets_test: 55 % of a landscape height.
    tester.view.viewInsets = const FakeViewPadding(bottom: 198);
    addTearDown(tester.view.resetViewInsets);
    await _pumpWorkspace(tester, TerminalStop.half);
    final pane = tester.element(find.byType(EditorPane));
    unawaited(askLineTarget(pane, lineCount: 120, currentLine: 7));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goto_line_dialog')), findsOneWidget);
    await _expectGolden(tester, 'chrome/goto_line_800x360_dark.png');
  });
}
