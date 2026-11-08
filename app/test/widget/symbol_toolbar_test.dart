/// The symbol toolbar in the workbench (Phase 2 W6, gate G6): keys type at
/// the editor's cursor without taking focus, pairs leave the cursor between
/// them, Tab and Shift+Tab, undo and redo from the page's history, the
/// arrows, the hide-keyboard key, presets per language, the user's own keys,
/// and a hardware keyboard putting the toolbar away while the soft keyboard
/// is down.
library;

import 'dart:async';

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/keyboard_state.dart';
import 'package:codeforge/application/settings_controller.dart';
import 'package:codeforge/design_system/components/workbench_chrome.dart';
import 'package:codeforge/features/settings/appearance_screen.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_hardware_keyboard.dart';
import 'test_harness.dart';

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkbenchScreen)),
  listen: false,
);

/// The workbench with [path] open and active.
Future<TestHarness> _pumpFile(
  WidgetTester tester, {
  String path = 'keys.js',
  String text = 'f\n',
  AppSettings settings = const AppSettings(welcomeSeen: true),
  FakeHardwareKeyboard? hardwareKeyboard,
}) async {
  setSurface(tester, 1280, 800);
  final harness = TestHarness(
    settings: settings,
    shell: const ShellState(lastRoute: '/workspace'),
    hardwareKeyboard: hardwareKeyboard,
  );
  harness.files.putText(path, text);
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  unawaited(
    _container(tester).read(documentControllerProvider.notifier).open(path),
  );
  await tester.pumpAndSettle();
  return harness;
}

String _docId(WidgetTester tester, String path) =>
    _container(tester).read(documentControllerProvider).documents[path]!.docId;

/// The page takes (or drops) the keyboard, as tapping into it does.
Future<void> _focusEditor(
  WidgetTester tester,
  TestHarness harness, {
  bool focused = true,
}) async {
  harness.editorSurface.emit('editor.focus', {'focused': focused});
  await tester.pumpAndSettle();
}

Finder _key(String id) => find.byKey(ValueKey('toolbar_$id'));

bool _enabled(WidgetTester tester, String id) =>
    tester.widget<InkWell>(_key(id)).onTap != null;

Future<void> _tapKey(WidgetTester tester, String id) async {
  await tester.tap(_key(id));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('keys type at the cursor and never take the focus', (
    tester,
  ) async {
    final harness = await _pumpFile(tester);
    await _focusEditor(tester, harness);
    final page = harness.editorSurface;
    final focus = FocusManager.instance.primaryFocus;

    // A pair leaves the cursor between its two halves: the next key lands
    // inside it.
    await _tapKey(tester, 'symbol:()');
    expect(page.inserts.last, (text: '()', cursorOffset: 1));
    await _tapKey(tester, 'symbol:;');
    expect(page.inserts.last, (text: ';', cursorOffset: null));
    expect(page.documents[_docId(tester, 'keys.js')]!.text, '(;)f\n');
    expect(FocusManager.instance.primaryFocus, same(focus));

    // The host mirrored every keystroke: the tab is dirty.
    expect(
      _container(tester).read(documentControllerProvider).active!.dirty,
      isTrue,
    );
  });

  testWidgets('keys are live only while the editor has the keyboard', (
    tester,
  ) async {
    final harness = await _pumpFile(tester);
    expect(find.byKey(const ValueKey('symbol_toolbar')), findsOneWidget);
    expect(_enabled(tester, 'indent'), isFalse);
    expect(_enabled(tester, 'symbol:{}'), isFalse);

    await _focusEditor(tester, harness);
    expect(_enabled(tester, 'indent'), isTrue);
    expect(_enabled(tester, 'symbol:{}'), isTrue);

    await _focusEditor(tester, harness, focused: false);
    expect(_enabled(tester, 'indent'), isFalse);
    expect(harness.editorSurface.inserts, isEmpty);
  });

  testWidgets('Tab, Shift+Tab and the arrows run the page commands', (
    tester,
  ) async {
    // A short row of the user's own keys leaves every key on screen.
    final harness = await _pumpFile(
      tester,
      settings: const AppSettings(welcomeSeen: true, toolbarKeys: '()'),
    );
    await _focusEditor(tester, harness);
    final start = harness.editorSurface.commands.length;
    for (final id in ['indent', 'outdent', 'left', 'up', 'down', 'right']) {
      await _tapKey(tester, id);
    }
    expect(harness.editorSurface.commands.sublist(start), [
      'insertIndent',
      'indentLess',
      'cursorCharLeft',
      'cursorLineUp',
      'cursorLineDown',
      'cursorCharRight',
    ]);
  });

  testWidgets('undo and redo follow the page history of the active file', (
    tester,
  ) async {
    final harness = await _pumpFile(
      tester,
      settings: const AppSettings(welcomeSeen: true, toolbarKeys: '()'),
    );
    await _focusEditor(tester, harness);
    final docId = _docId(tester, 'keys.js');
    expect(_enabled(tester, 'undo'), isFalse);
    expect(_enabled(tester, 'redo'), isFalse);

    harness.editorSurface.emit('editor.history', {
      'docId': docId,
      'canUndo': true,
      'canRedo': false,
    });
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'undo'), isTrue);
    expect(_enabled(tester, 'redo'), isFalse);
    await _tapKey(tester, 'undo');
    expect(harness.editorSurface.commands.last, 'undo');

    // Another document's history leaves this one's keys alone.
    harness.editorSurface.emit('editor.history', {
      'docId': 'elsewhere',
      'canUndo': false,
      'canRedo': true,
    });
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'undo'), isTrue);
    expect(_enabled(tester, 'redo'), isFalse);
  });

  testWidgets('long-pressing a key types its other variant', (tester) async {
    final harness = await _pumpFile(
      tester,
      settings: const AppSettings(welcomeSeen: true, toolbarKeys: '" {}'),
    );
    await _focusEditor(tester, harness);
    await tester.longPress(_key('symbol:"'));
    await tester.pumpAndSettle();
    expect(harness.editorSurface.inserts.last, (text: '""', cursorOffset: 1));
    await tester.longPress(_key('symbol:{}'));
    await tester.pumpAndSettle();
    expect(harness.editorSurface.inserts.last, (text: '{', cursorOffset: null));
  });

  testWidgets('the hide key closes the keyboard of whoever has it', (
    tester,
  ) async {
    final harness = await _pumpFile(tester);
    expect(_enabled(tester, 'hide_keyboard'), isFalse);

    // The editor has it: the page drops its focus.
    await _focusEditor(tester, harness);
    await _tapKey(tester, 'hide_keyboard');
    expect(harness.editorSurface.commands.last, 'blur');

    // The find bar's field has it: the field lets go.
    await _focusEditor(tester, harness, focused: false);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(_container(tester).read(softKeyboardVisibleProvider), isTrue);
    final query = find.descendant(
      of: find.byKey(const ValueKey('find_query')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(query).focusNode.hasFocus, isTrue);
    final blurs = harness.editorSurface.commands.where((c) => c == 'blur');
    final blursBefore = blurs.length;
    await _tapKey(tester, 'hide_keyboard');
    expect(tester.widget<EditableText>(query).focusNode.hasFocus, isFalse);
    expect(blurs.length, blursBefore);
  });

  testWidgets('the preset follows the language of the active file', (
    tester,
  ) async {
    final harness = await _pumpFile(tester, path: 'main.py', text: 'x = 1\n');
    expect(_key('symbol::'), findsOneWidget);
    expect(_key('symbol:=>'), findsNothing);

    harness.files.putText('page.js', 'let a;\n');
    unawaited(
      _container(
        tester,
      ).read(documentControllerProvider.notifier).open('page.js'),
    );
    await tester.pumpAndSettle();
    expect(_key('symbol:=>'), findsOneWidget);
  });

  testWidgets("the user's own keys replace the presets", (tester) async {
    await _pumpFile(
      tester,
      settings: const AppSettings(welcomeSeen: true, toolbarKeys: '; ->'),
    );
    expect(_key('symbol:;'), findsOneWidget);
    expect(_key('symbol:->'), findsOneWidget);
    expect(_key('symbol:{}'), findsNothing);
  });

  testWidgets('compact keeps Tab and a few symbols; off has no toolbar', (
    tester,
  ) async {
    await _pumpFile(
      tester,
      settings: const AppSettings(
        welcomeSeen: true,
        toolbarPreset: ToolbarPreset.compact,
      ),
    );
    expect(_key('indent'), findsOneWidget);
    expect(_key('outdent'), findsNothing);
    expect(_key('undo'), findsNothing);
    expect(_key('hide_keyboard'), findsOneWidget);

    await _container(tester)
        .read(settingsControllerProvider.notifier)
        .setToolbarPreset(ToolbarPreset.none);
    await tester.pumpAndSettle();
    expect(find.byType(CfSymbolToolbar), findsNothing);
  });

  testWidgets('a hardware keyboard puts the toolbar away', (tester) async {
    final keyboard = FakeHardwareKeyboard();
    await _pumpFile(tester, hardwareKeyboard: keyboard);
    expect(find.byType(CfSymbolToolbar), findsOneWidget);

    keyboard.attached = true;
    await tester.pumpAndSettle();
    expect(_container(tester).read(hardwareKeyboardProvider), isTrue);
    expect(find.byType(CfSymbolToolbar), findsNothing);

    // The soft keyboard up beside it (Android can show both): the soft
    // keyboard has no symbols, so the toolbar comes back with it.
    addTearDown(tester.view.resetViewInsets);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(find.byType(CfSymbolToolbar), findsOneWidget);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byType(CfSymbolToolbar), findsNothing);

    keyboard.attached = false;
    await tester.pumpAndSettle();
    expect(find.byType(CfSymbolToolbar), findsOneWidget);
  });

  testWidgets('keys are 48 dp touch targets with spoken labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final harness = await _pumpFile(
      tester,
      settings: const AppSettings(welcomeSeen: true, toolbarKeys: '() ;'),
    );
    await _focusEditor(tester, harness);
    for (final id in ['indent', 'symbol:()', 'symbol:;', 'hide_keyboard']) {
      final size = tester.getSize(_key(id));
      expect(size.width, greaterThanOrEqualTo(48), reason: id);
      expect(size.height, greaterThanOrEqualTo(48), reason: id);
    }
    expect(
      tester.getSize(find.byType(CfSymbolToolbar)).height,
      CfSymbolToolbar.extent,
    );
    expect(
      tester.getSemantics(_key('symbol:()')),
      isSemantics(label: 'Insert parentheses', isButton: true),
    );
    expect(
      tester.getSemantics(_key('hide_keyboard')),
      isSemantics(label: 'Hide keyboard', isButton: true),
    );
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });

  testWidgets('Appearance keeps the user keys', (tester) async {
    setSurface(tester, 412, 915);
    final harness = TestHarness();
    await tester.pumpWidget(harness.wrap(const AppearanceScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('toolbar_keys_tile')),
      200,
    );
    await tester.tap(find.byKey(const ValueKey('toolbar_keys_tile')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('toolbar_keys_field')),
      '  ; =>  ',
    );
    await tester.tap(find.byKey(const ValueKey('toolbar_keys_save')));
    await tester.pumpAndSettle();
    expect(harness.settingsStore.load().toolbarKeys, '; =>');
    expect(find.text('; =>'), findsOneWidget);
  });
}
