/// The explorer's operations (Phase 3 W4, gate G3): each row's menu from a
/// long-press, the selected row's ⋯ button or the keyboard; New File and
/// New Folder in the row's folder; Rename, Move to…, Duplicate, Copy Path
/// and Delete, each through its dialog, with a taken name asked again;
/// what a provider does not allow left out; open tabs following; a tab
/// kept for a deleted file; the arrow keys; and a tree of 10,000 entries
/// that builds only the rows on screen.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/design_system/components/file_tree.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/memory_file_service.dart';
import 'test_harness.dart';

Finder _row(String path) => find.byKey(ValueKey('tree_$path'));

Finder _menuItem(String action) =>
    find.byKey(ValueKey('explorer_menu_$action'));

DocumentsState _state(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkbenchScreen)),
  listen: false,
).read(documentControllerProvider);

Future<TestHarness> _pumpWorkbench(
  WidgetTester tester, {
  MemoryFileService? files,
}) async {
  setSurface(tester, 1280, 800);
  final harness = TestHarness(
    files: files,
    shell: const ShellState(lastRoute: '/workspace'),
  );
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _openMenu(WidgetTester tester, String path) async {
  await tester.longPress(_row(path));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String action) async {
  await tester.tap(_menuItem(action));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String field, String text) async {
  await tester.enterText(find.byKey(ValueKey(field)), text);
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a long-press opens the menu; rename asks again for a taken '
      'name, and the tab follows', (tester) async {
    final harness = await _pumpWorkbench(tester);
    expect(_state(tester).openPaths, ['main.js']);

    await _openMenu(tester, 'main.js');
    for (final action in [
      'newFile',
      'newFolder',
      'rename',
      'move',
      'duplicate',
      'copyPath',
      'delete',
    ]) {
      expect(_menuItem(action), findsOneWidget, reason: action);
    }
    await _choose(tester, 'rename');
    expect(find.byKey(const ValueKey('name_dialog')), findsOneWidget);
    await _type(tester, 'name_field', 'utils.js');
    await _tapKey(tester, 'name_confirm');
    expect(
      find.text('“utils.js” is taken in this folder. Choose another name.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('name_dialog')), findsOneWidget);
    expect(harness.files.exists('main.js'), isTrue);

    await _type(tester, 'name_field', 'index.js');
    await _tapKey(tester, 'name_confirm');
    expect(find.byKey(const ValueKey('name_dialog')), findsNothing);
    expect(harness.files.exists('main.js'), isFalse);
    expect(harness.files.textOf('index.js'), isNotNull);
    expect(_row('index.js'), findsOneWidget);
    expect(_row('main.js'), findsNothing);
    expect(_state(tester).openPaths, ['index.js']);
    expect(_state(tester).activePath, 'index.js');
  });

  testWidgets("the selected row's ⋯ opens the same menu, without what the "
      'provider does not allow', (tester) async {
    final files = MemoryFileService();
    files.capabilities['utils.js'] = const FileCapabilities(
      rename: false,
      delete: false,
    );
    await _pumpWorkbench(tester, files: files);

    expect(find.byKey(const ValueKey('tree_menu_utils.js')), findsNothing);
    await tester.tap(_row('utils.js'));
    await tester.pumpAndSettle();
    expect(_state(tester).activePath, 'utils.js');
    await tester.tap(find.byKey(const ValueKey('tree_menu_utils.js')));
    await tester.pumpAndSettle();
    expect(_menuItem('move'), findsOneWidget);
    expect(_menuItem('duplicate'), findsOneWidget);
    expect(_menuItem('copyPath'), findsOneWidget);
    expect(_menuItem('rename'), findsNothing);
    expect(_menuItem('delete'), findsNothing);
  });

  testWidgets('new folder and new file go into the folder of the row', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);
    await _openMenu(tester, 'src');
    await _choose(tester, 'newFolder');
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('file_path_field')),
    );
    expect(field.controller!.text, 'src/');
    await _type(tester, 'file_path_field', 'src/lib/');
    await _tapKey(tester, 'file_path_confirm');
    expect(harness.files.isFolder('src/lib'), isTrue);
    expect(_row('src/lib'), findsOneWidget, reason: 'its folder expanded');

    await _openMenu(tester, 'src/lib');
    await _choose(tester, 'newFile');
    await _type(tester, 'file_path_field', 'src/lib/util.js');
    await _tapKey(tester, 'file_path_confirm');
    expect(harness.files.textOf('src/lib/util.js'), '');
    expect(_state(tester).activePath, 'src/lib/util.js');
    expect(_row('src/lib/util.js'), findsOneWidget);

    // A taken path keeps the dialog open, saying so.
    await _openMenu(tester, 'src');
    await _choose(tester, 'newFile');
    await _type(tester, 'file_path_field', 'src/notes.txt');
    await _tapKey(tester, 'file_path_confirm');
    expect(find.text('src/notes.txt already exists.'), findsOneWidget);
    expect(find.byKey(const ValueKey('file_path_dialog')), findsOneWidget);
    await _tapKey(tester, 'file_path_cancel');
  });

  testWidgets('move to… offers the folders and moves the file with its tab', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);
    harness.files.putText('src/main.js', '// another\n');
    await _openMenu(tester, 'main.js');
    await _choose(tester, 'move');
    expect(find.byKey(const ValueKey('move_dialog')), findsOneWidget);
    // Where it is already can't be chosen.
    await _tapKey(tester, 'move_target_');
    final confirm = tester.widget<FilledButton>(
      find.byKey(const ValueKey('move_confirm')),
    );
    expect(confirm.onPressed, isNull);

    await _tapKey(tester, 'move_target_src');
    await _tapKey(tester, 'move_confirm');
    expect(find.byKey(const ValueKey('move_problem')), findsOneWidget);
    expect(find.byKey(const ValueKey('move_dialog')), findsOneWidget);
    await _tapKey(tester, 'move_cancel');

    harness.files.remove('src/main.js');
    await _openMenu(tester, 'main.js');
    await _choose(tester, 'move');
    await _tapKey(tester, 'move_target_src');
    await _tapKey(tester, 'move_confirm');
    expect(find.byKey(const ValueKey('move_dialog')), findsNothing);
    expect(harness.files.exists('main.js'), isFalse);
    expect(harness.files.textOf('src/main.js'), isNotNull);
    expect(_state(tester).openPaths, ['src/main.js']);
    expect(_row('src/main.js'), findsOneWidget);
  });

  testWidgets('duplicate takes a free name; copy path fills the clipboard', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = call.arguments as Map<Object?, Object?>;
          clipboard = arguments['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await _openMenu(tester, 'utils.js');
    await _choose(tester, 'duplicate');
    expect(
      harness.files.textOf('utils copy.js'),
      harness.files.textOf('utils.js'),
    );
    expect(_row('utils copy.js'), findsOneWidget);

    await _openMenu(tester, 'utils.js');
    await _choose(tester, 'copyPath');
    expect(clipboard, 'utils.js');
    expect(find.text('Copied utils.js'), findsOneWidget);
  });

  testWidgets('delete asks first and counts a folder; an unsaved tab stays, '
      'marked deleted, until it is saved again', (tester) async {
    final harness = await _pumpWorkbench(tester);
    await tester.tap(_row('src'));
    await tester.pumpAndSettle();
    await tester.tap(_row('src/notes.txt'));
    await tester.pumpAndSettle();
    harness.editorSurface.typeText('mine\n');
    await tester.pumpAndSettle();

    await _openMenu(tester, 'src');
    await _choose(tester, 'delete');
    expect(find.byKey(const ValueKey('delete_dialog')), findsOneWidget);
    expect(find.text('Delete the folder src?'), findsOneWidget);
    expect(
      find.textContaining('src is deleted with the 2 files in it.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('One open file has unsaved changes.'),
      findsOneWidget,
    );
    expect(find.textContaining('This can’t be undone.'), findsOneWidget);
    await _tapKey(tester, 'delete_cancel');
    expect(harness.files.isFolder('src'), isTrue);

    await _openMenu(tester, 'src');
    await _choose(tester, 'delete');
    await _tapKey(tester, 'delete_confirm');
    expect(harness.files.isFolder('src'), isFalse);
    expect(_row('src'), findsNothing);
    final kept = _state(tester).documents['src/notes.txt']!;
    expect(kept.deletedOnDisk, isTrue);
    expect(kept.dirty, isTrue);
    final notice = find.byKey(const ValueKey('deleted_notice'));
    expect(notice, findsOneWidget);

    await tester.tap(find.descendant(of: notice, matching: find.text('Save')));
    await tester.pumpAndSettle();
    expect(harness.files.textOf('src/notes.txt'), endsWith('mine\n'));
    expect(_state(tester).documents['src/notes.txt']!.deletedOnDisk, isFalse);
    expect(find.byKey(const ValueKey('deleted_notice')), findsNothing);
  });

  testWidgets('the arrow keys move through the tree; Enter opens; Shift+F10 '
      'opens the menu', (tester) async {
    await _pumpWorkbench(tester);
    await tester.tap(_row('src'));
    await tester.pumpAndSettle();
    expect(_row('src/greeting.dart'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('tree_menu_src/greeting.dart')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_state(tester).activePath, 'src/greeting.dart');
    // Back to the tree, wherever the open document took the focus.
    await tester.tap(_row('src/greeting.dart'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(_menuItem('rename'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_menuItem('rename'), findsNothing);

    // Left: to the folder, then the folder collapses.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tree_menu_src')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(_row('src/greeting.dart'), findsNothing);
    // Right expands it again, and steps into it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('tree_menu_src/greeting.dart')),
      findsOneWidget,
    );
  });

  testWidgets('at 10,000 entries the tree builds only the rows on screen '
      '(G3)', (tester) async {
    final files = MemoryFileService(
      seed: {
        'main.js': 'main();\n',
        for (var i = 0; i < 10000; i++)
          'big/file_${i.toString().padLeft(5, '0')}.txt': '',
      },
    );
    await _pumpWorkbench(tester, files: files);
    await tester.tap(_row('big'));
    await tester.pumpAndSettle();
    expect(_row('big/file_00000.txt'), findsOneWidget);
    final built = find.byType(CfTreeRow).evaluate().length;
    expect(built, lessThan(60), reason: '$built rows built');

    final tree = tester.widget<ListView>(
      find.byKey(const ValueKey('explorer_tree')),
    );
    final scroll = tree.controller!;
    expect(scroll.position.maxScrollExtent, greaterThan(10000 * 47.0));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(_row('main.js'), findsOneWidget);
    expect(_row('big/file_09999.txt'), findsOneWidget);
    expect(_row('big/file_00000.txt'), findsNothing);
    expect(find.byType(CfTreeRow).evaluate().length, lessThan(60));
  });
}
