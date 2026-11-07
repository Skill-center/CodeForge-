/// Find, replace and go to line in the workbench (Phase 2 W6, gate G5):
/// the find bar over the scripted page with its keys, toggles and replace
/// row; the shortcuts and palette commands that open it; go to line; and
/// undo and redo from the palette.
library;

import 'dart:async';

import 'package:codeforge/application/commands.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/find_controller.dart';
import 'package:codeforge/design_system/components/buttons.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_harness.dart';

/// Five `a`s, three of them whole words.
const String _text = 'let a = 1;\nlet ab = a + a;\nreturn ab;\n';

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkbenchScreen)),
  listen: false,
);

/// The workbench at [width] × [height] with find.js open and active.
Future<TestHarness> _pumpFile(
  WidgetTester tester, {
  double width = 1280,
  double height = 800,
}) async {
  setSurface(tester, width, height);
  final harness = TestHarness(
    shell: const ShellState(lastRoute: '/workspace'),
  );
  harness.files.putText('find.js', _text);
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  unawaited(
    _container(tester).read(documentControllerProvider.notifier).open(
      'find.js',
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

/// The page's copy of find.js.
String _pageText(WidgetTester tester, TestHarness harness) {
  final docId = _container(
    tester,
  ).read(documentControllerProvider).documents['find.js']!.docId;
  return harness.editorSurface.documents[docId]!.text;
}

/// Presses Ctrl + [key] where Flutter has the keyboard.
Future<void> _chord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

String _count(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('find_count'))).data!;

CfIconButton _button(WidgetTester tester, String key) =>
    tester.widget<CfIconButton>(find.byKey(ValueKey(key)));

/// Runs the palette command [id], as choosing it in the palette does.
void _runCommand(WidgetTester tester, String id) {
  final commands = _container(tester).read(commandRegistryProvider).commands;
  commands.firstWhere((c) => c.id == id).onExecute();
}

void main() {
  testWidgets('Ctrl+F finds the selection; Enter steps, Escape closes', (
    tester,
  ) async {
    final harness = await _pumpFile(tester);
    final page = harness.editorSurface;
    page.moveCursor(4, head: 5);
    await tester.pumpAndSettle();

    await _chord(tester, LogicalKeyboardKey.keyF);
    expect(find.byKey(const ValueKey('find_bar')), findsOneWidget);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('find_query')),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, 'a');
    expect(field.focusNode!.hasFocus, isTrue);
    expect(_count(tester), '1 of 5');

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(_count(tester), '2 of 5');
    expect(field.focusNode!.hasFocus, isTrue, reason: 'Enter keeps the field');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(_count(tester), '1 of 5');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find_bar')), findsNothing);
    expect(page.searchSpec, isNull);
    // The field had the keyboard, so the editor gets it back.
    expect(page.commands.sublist(page.commands.length - 2), [
      'closeSearch',
      'focus',
    ]);
  });

  testWidgets('toggles narrow the search; a broken pattern says so', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpFile(tester);
    await _chord(tester, LogicalKeyboardKey.keyF);
    await tester.enterText(find.byKey(const ValueKey('find_query')), 'A');
    await tester.pumpAndSettle();
    expect(_count(tester), '5 results');

    await tester.tap(find.byKey(const ValueKey('find_case')));
    await tester.pumpAndSettle();
    expect(_count(tester), 'No results');
    // One node for TalkBack, saying what it is and that it is on.
    expect(
      tester.getSemantics(find.byKey(const ValueKey('find_case'))),
      isSemantics(
        label: 'Match case',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('find_case')));
    await tester.tap(find.byKey(const ValueKey('find_word')));
    await tester.pumpAndSettle();
    expect(_count(tester), '3 results');

    await tester.tap(find.byKey(const ValueKey('find_word')));
    await tester.tap(find.byKey(const ValueKey('find_regex')));
    await tester.enterText(find.byKey(const ValueKey('find_query')), '(');
    await tester.pumpAndSettle();
    expect(_count(tester), 'Invalid pattern');
    expect(_button(tester, 'find_next').onPressed, isNull);
    expect(_button(tester, 'find_previous').onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('find_query')), 'a|b');
    await tester.pumpAndSettle();
    expect(_count(tester), '7 results');
    semantics.dispose();
  });

  testWidgets('Ctrl+H replaces one, then all; the tab turns dirty', (
    tester,
  ) async {
    final harness = await _pumpFile(tester);
    await _chord(tester, LogicalKeyboardKey.keyH);
    expect(find.byKey(const ValueKey('find_replacement')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('find_query')), 'a');
    await tester.enterText(find.byKey(const ValueKey('find_replacement')), 'x');
    await tester.pumpAndSettle();

    // The first press selects a match; the second replaces it.
    await tester.tap(find.byKey(const ValueKey('find_replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('find_replace')));
    await tester.pumpAndSettle();
    expect(
      _pageText(tester, harness),
      'let x = 1;\nlet ab = a + a;\nreturn ab;\n',
    );

    await tester.tap(find.byKey(const ValueKey('find_replace_all')));
    await tester.pumpAndSettle();
    expect(
      _pageText(tester, harness),
      'let x = 1;\nlet xb = x + x;\nreturn xb;\n',
    );
    expect(_count(tester), 'No results');
    final documents = _container(tester).read(documentControllerProvider);
    expect(documents.documents['find.js']!.dirty, isTrue);
    // Nothing left to replace: the buttons rest.
    expect(_button(tester, 'find_replace').onPressed, isNull);
    expect(_button(tester, 'find_replace_all').onPressed, isNull);
  });

  testWidgets('Ctrl+G goes to a line and column, refusing nonsense', (
    tester,
  ) async {
    final harness = await _pumpFile(tester);
    final page = harness.editorSurface;
    await _chord(tester, LogicalKeyboardKey.keyG);
    expect(find.byKey(const ValueKey('goto_line_dialog')), findsOneWidget);
    expect(find.text('Now on line 1'), findsOneWidget);
    expect(find.text('1 to 4'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('goto_line_field')), 'x');
    await tester.tap(find.byKey(const ValueKey('goto_line_confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Type a line number, like 42 or 42:7.'), findsOneWidget);
    expect(page.gotoLines, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('goto_line_field')),
      '2:5',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goto_line_dialog')), findsNothing);
    expect(page.gotoLines.single, (line: 2, column: 5));
    final docId = _container(
      tester,
    ).read(documentControllerProvider).documents['find.js']!.docId;
    expect(page.documents[docId]!.head, 15);
    expect(page.commands.last, 'focus');
  });

  testWidgets('palette commands and page shortcuts reach the editor', (
    tester,
  ) async {
    final harness = await _pumpFile(tester);
    final page = harness.editorSurface;

    _runCommand(tester, 'edit.undo');
    _runCommand(tester, 'edit.redo');
    await tester.pumpAndSettle();
    expect(page.commands, containsAllInOrder(['undo', 'redo']));

    _runCommand(tester, 'edit.gotoLine');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goto_line_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('goto_line_cancel')));
    await tester.pumpAndSettle();
    expect(page.gotoLines, isEmpty);

    _runCommand(tester, 'edit.replace');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find_replacement')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('find_close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find_bar')), findsNothing);

    // While the editor has the keyboard, the page forwards the keys.
    page.pressShortcut('find');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find_bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('find_replacement')), findsNothing);
    page.pressEscapeInEditor();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find_bar')), findsNothing);
    page.pressShortcut('gotoLine');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goto_line_dialog')), findsOneWidget);
  });

  testWidgets('a phone gets the options on a row of their own', (
    tester,
  ) async {
    await _pumpFile(tester, width: 360, height: 800);
    final controller = _container(tester).read(findControllerProvider.notifier);
    unawaited(controller.open(replace: true));
    await tester.pumpAndSettle();
    final query = tester.getCenter(find.byKey(const ValueKey('find_query')));
    final replace = tester.getCenter(
      find.byKey(const ValueKey('find_replacement')),
    );
    final options = tester.getCenter(find.byKey(const ValueKey('find_case')));
    expect(replace.dy, greaterThan(query.dy));
    expect(options.dy, greaterThan(replace.dy));
    for (final key in ['find_previous', 'find_next', 'find_close']) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the open bar meets the tap target guidelines (G7)', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpFile(tester, width: 412, height: 915);
    final controller = _container(tester).read(findControllerProvider.notifier);
    unawaited(controller.open(replace: true));
    await tester.pumpAndSettle();
    controller.setQuery('a');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find_replace_all')), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    final field = tester.getSize(find.byKey(const ValueKey('find_query')));
    expect(field.height, greaterThanOrEqualTo(48));
    semantics.dispose();
  });

  testWidgets('a wide pane keeps the options beside the query', (
    tester,
  ) async {
    await _pumpFile(tester);
    await _chord(tester, LogicalKeyboardKey.keyF);
    final query = tester.getCenter(find.byKey(const ValueKey('find_query')));
    final options = tester.getCenter(find.byKey(const ValueKey('find_regex')));
    expect(options.dy, moreOrLessEquals(query.dy, epsilon: 1));
    expect(
      tester.getSize(find.byKey(const ValueKey('find_regex'))),
      const Size(48, 48),
    );
  });
}
