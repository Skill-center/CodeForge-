/// Documents in the workbench (Phase 2 W4, W5 and W7, gates G2–G4 and G7):
/// many tabs, asking before unsaved changes are lost, Save As and New File
/// dialogs, refused files, line-ending chips, keyboard shortcuts, tabs that
/// come back after a restart, unsaved edits that survive the app being
/// killed, and large files opened as plain text. The editor is the scripted
/// page; files and the session store are the harness's in-memory ones.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/documents/document_state.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/core/editor/large_files.dart';
import 'package:codeforge/core/files/text_codec.dart';
import 'package:codeforge/design_system/components/workbench_chrome.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/flaky_session_store.dart';
import 'test_harness.dart';

/// Tab labels, scoped to the strip: the docked explorer shows names too.
Finder _tabText(String label) =>
    find.descendant(of: find.byType(CfTabStrip), matching: find.text(label));

/// The close cross of [path]'s tab; a dirty tab shows a dot instead.
Finder _closeCross(String path) => find.descendant(
  of: find.byKey(ValueKey('tab_close_$path')),
  matching: find.byIcon(Icons.close),
);

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkbenchScreen)),
  listen: false,
);

DocumentsState _state(WidgetTester tester) =>
    _container(tester).read(documentControllerProvider);

DocumentController _documents(WidgetTester tester) =>
    _container(tester).read(documentControllerProvider.notifier);

/// Whether [label]'s tab is inside the strip's visible scroll area.
bool _inView(WidgetTester tester, String label) {
  final viewport = tester.getRect(
    find.descendant(
      of: find.byType(CfTabStrip),
      matching: find.byType(Scrollable),
    ),
  );
  final tab = tester.getRect(_tabText(label));
  return tab.left >= viewport.left - 0.5 && tab.right <= viewport.right + 0.5;
}

/// Presses Ctrl (and Shift) + [key] where Flutter has the keyboard.
Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyEvent(key);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

Future<TestHarness> _pumpWorkbench(
  WidgetTester tester, {
  ShellState shell = const ShellState(lastRoute: '/workspace'),
  void Function(TestHarness harness)? before,
}) async {
  setSurface(tester, 1280, 800);
  final harness = TestHarness(shell: shell);
  before?.call(harness);
  await tester.pumpWidget(harness.app());
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  testWidgets('a dozen tabs each keep their own document (G3)', (tester) async {
    final harness = await _pumpWorkbench(
      tester,
      before: (harness) {
        for (var i = 1; i <= 11; i++) {
          harness.files.putText('tabs/t$i.js', '// tab $i\n');
        }
      },
    );
    final documents = _documents(tester);
    for (var i = 1; i <= 11; i++) {
      await documents.open('tabs/t$i.js');
    }
    await tester.pumpAndSettle();
    final page = harness.editorSurface;
    expect(_state(tester).openPaths, hasLength(12));
    expect(page.documents, hasLength(12));
    expect(_inView(tester, 't11.js'), isTrue, reason: 'the newest tab shows');

    documents.activate('tabs/t2.js');
    await tester.pumpAndSettle();
    page.typeText('two\n');
    documents.activate('tabs/t9.js');
    await tester.pumpAndSettle();
    page.typeText('nine\n');
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.dirtyPaths, ['tabs/t2.js', 'tabs/t9.js']);
    String pageText(String path) =>
        page.documents[state.documents[path]!.docId]!.text;
    expect(pageText('tabs/t2.js'), '// tab 2\ntwo\n');
    expect(pageText('tabs/t9.js'), '// tab 9\nnine\n');
    expect(pageText('tabs/t5.js'), '// tab 5\n');
    expect(_closeCross('tabs/t2.js'), findsNothing, reason: 'dirty dot');
    expect(_closeCross('tabs/t5.js'), findsOneWidget);

    // Back to the first tab: the strip scrolls it into view.
    documents.activate('main.js');
    await tester.pumpAndSettle();
    expect(_inView(tester, 'main.js'), isTrue);
    expect(_inView(tester, 't11.js'), isFalse);

    // Ctrl+Shift+Tab wraps to the last tab, which comes into view.
    await _chord(tester, LogicalKeyboardKey.tab, shift: true);
    expect(_state(tester).activePath, 'tabs/t11.js');
    expect(_inView(tester, 't11.js'), isTrue);
    expect(page.activeDocId, _state(tester).documents['tabs/t11.js']!.docId);
    await _chord(tester, LogicalKeyboardKey.tab);
    expect(_state(tester).activePath, 'main.js');
  });

  testWidgets('closing an unsaved tab asks: cancel, don’t save, save (G3)', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);
    final page = harness.editorSurface;
    final mainBefore = harness.files.textOf('main.js')!;
    final appBefore = harness.files.textOf('app.py');

    await tester.tap(find.byKey(const ValueKey('tree_app.py')));
    await tester.pumpAndSettle();
    page.typeText('# edited\n');
    await tester.pumpAndSettle();
    expect(_closeCross('app.py'), findsNothing, reason: 'dirty dot');

    // Cancel: nothing changes.
    await tester.tap(find.byKey(const ValueKey('tab_close_app.py')));
    await tester.pumpAndSettle();
    expect(find.text('Save changes to app.py?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('unsaved_cancel')));
    await tester.pumpAndSettle();
    expect(_tabText('app.py'), findsOneWidget);
    expect(_state(tester).dirtyPaths, ['app.py']);

    // Don't save: the tab closes and the file is as it was.
    await tester.tap(find.byKey(const ValueKey('tab_close_app.py')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('unsaved_discard')));
    await tester.pumpAndSettle();
    expect(_tabText('app.py'), findsNothing);
    expect(harness.files.textOf('app.py'), appBefore);

    // Save: written first, then closed.
    expect(_state(tester).activePath, 'main.js');
    page.typeText('// kept\n');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tab_close_main.js')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('unsaved_save')));
    await tester.pumpAndSettle();
    expect(_tabText('main.js'), findsNothing);
    expect(harness.files.textOf('main.js'), '$mainBefore// kept\n');
    expect(find.text('New file'), findsOneWidget, reason: 'empty state');
  });

  testWidgets('save as moves the tab; an existing name asks first (G2)', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);
    final appBefore = harness.files.textOf('app.py');

    Future<void> saveAs(String path) async {
      await tester.tap(find.byKey(const ValueKey('editor_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu_save_as')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('file_path_dialog')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('file_path_field')),
        path,
      );
      await tester.tap(find.byKey(const ValueKey('file_path_confirm')));
      await tester.pumpAndSettle();
    }

    await saveAs('app.py');
    expect(find.text('Replace app.py?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm_cancel')));
    await tester.pumpAndSettle();
    expect(harness.files.textOf('app.py'), appBefore);
    expect(_tabText('main.js'), findsOneWidget);

    await saveAs('src/copy.js');
    expect(_tabText('copy.js'), findsOneWidget);
    expect(_tabText('main.js'), findsNothing);
    expect(
      harness.files.textOf('src/copy.js'),
      harness.files.textOf('main.js'),
    );
    expect(_state(tester).activePath, 'src/copy.js');
  });

  testWidgets('new file: bad paths are explained, good ones open (G2)', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);

    await tester.tap(find.byKey(const ValueKey('explorer_new_file')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('file_path_field')),
      '../escape.js',
    );
    await tester.tap(find.byKey(const ValueKey('file_path_confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('file_path_dialog')), findsOneWidget);
    expect(
      find.text('The path cannot contain "." or ".." folders.'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('file_path_field')),
      'notes/todo.md',
    );
    await tester.tap(find.byKey(const ValueKey('file_path_confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('file_path_dialog')), findsNothing);
    expect(harness.files.textOf('notes/todo.md'), '');
    expect(_tabText('todo.md'), findsOneWidget);
    expect(find.byKey(const ValueKey('tree_notes')), findsOneWidget);

    // The same name again: refused, with a reason.
    await tester.tap(find.byKey(const ValueKey('explorer_new_file')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('file_path_field')),
      'notes/todo.md',
    );
    await tester.tap(find.byKey(const ValueKey('file_path_confirm')));
    await tester.pumpAndSettle();
    expect(find.text('notes/todo.md already exists.'), findsOneWidget);
  });

  testWidgets('binary files are refused; CRLF and BOM show in the status', (
    tester,
  ) async {
    await _pumpWorkbench(
      tester,
      before: (harness) {
        harness.files
          ..putBytes('logo.png', [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x00])
          ..putText(
            'win.txt',
            'a\nb\n',
            format: const TextFormat(lineEnding: LineEnding.crlf, bom: true),
          );
      },
    );
    await tester.tap(find.byKey(const ValueKey('tree_logo.png')));
    await tester.pumpAndSettle();
    expect(
      find.text('This looks like a binary file, so it was not opened as text.'),
      findsOneWidget,
    );
    expect(_tabText('logo.png'), findsNothing);

    Finder chip(String key, String label) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.text(label),
    );
    expect(chip('status_eol', 'LF'), findsOneWidget, reason: 'main.js');
    expect(find.byKey(const ValueKey('status_bom')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tree_win.txt')));
    await tester.pumpAndSettle();
    expect(chip('status_eol', 'CRLF'), findsOneWidget);
    expect(chip('status_bom', 'BOM'), findsOneWidget);
    expect(chip('status_language', 'plaintext'), findsOneWidget);
  });

  testWidgets('Ctrl+S, and the page’s own shortcuts, save and close', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(tester);
    final page = harness.editorSurface;

    page.typeText('// by key\n');
    await tester.pumpAndSettle();
    await _chord(tester, LogicalKeyboardKey.keyS);
    expect(harness.files.textOf('main.js'), endsWith('// by key\n'));
    expect(_state(tester).dirtyPaths, isEmpty);

    // While the editor page has the keyboard, it forwards the shortcut.
    page.typeText('// by page\n');
    await tester.pumpAndSettle();
    page.pressShortcut('save');
    await tester.pumpAndSettle();
    expect(harness.files.textOf('main.js'), endsWith('// by page\n'));

    page.pressShortcut('closeTab');
    await tester.pumpAndSettle();
    expect(_tabText('main.js'), findsNothing, reason: 'clean: no question');
  });

  testWidgets('close others asks only about unsaved tabs', (tester) async {
    final harness = await _pumpWorkbench(tester);
    final page = harness.editorSurface;
    final documents = _documents(tester);
    await documents.open('app.py');
    await documents.open('utils.js');
    documents.activate('app.py');
    await tester.pumpAndSettle();
    page.typeText('# unsaved\n');
    documents.activate('utils.js');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('editor_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu_close_others')));
    await tester.pumpAndSettle();
    expect(find.text('Save changes to app.py?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('unsaved_discard')));
    await tester.pumpAndSettle();
    expect(_state(tester).openPaths, ['utils.js']);
    expect(_state(tester).activePath, 'utils.js');
  });

  testWidgets('tabs and the active one come back after a restart (G3)', (
    tester,
  ) async {
    final harness = await _pumpWorkbench(
      tester,
      shell: const ShellState(
        lastRoute: '/workspace',
        openTabs: ['app.py', 'gone.js', 'utils.js'],
        activeTab: 'utils.js',
      ),
    );
    expect(_state(tester).openPaths, ['app.py', 'utils.js']);
    expect(_state(tester).activePath, 'utils.js');
    expect(_tabText('main.js'), findsNothing, reason: 'no fallback needed');
    var page = harness.editorSurface;
    expect(
      page.documents[page.activeDocId]!.text,
      harness.files.textOf('utils.js'),
    );

    // Open one more, let the layout memory save, then restart.
    await tester.tap(find.byKey(const ValueKey('tree_README.md')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(_state(tester).openPaths, ['app.py', 'utils.js', 'README.md']);
    expect(_state(tester).activePath, 'README.md');
    page = harness.editorSurface;
    expect(page.documents, hasLength(3));
    expect(
      page.documents[page.activeDocId]!.text,
      harness.files.textOf('README.md'),
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('unsaved edits survive the app being killed; a file changed '
      'meanwhile asks which to keep (G4)', (tester) async {
    final harness = await _pumpWorkbench(tester);
    expect(_state(tester).activePath, 'main.js');
    var page = harness.editorSurface;
    page.typeText('// unsaved work\n');
    await tester.pumpAndSettle();
    final work = page.documents[page.activeDocId]!.text;
    expect(_closeCross('main.js'), findsNothing, reason: 'dirty: a dot');
    await tester.pump(const Duration(seconds: 2));

    // Killed: the next app starts over the same files and stores, without
    // a pause or a save in between.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    page = harness.editorSurface;
    expect(_state(tester).activePath, 'main.js');
    expect(_state(tester).active!.dirty, isTrue);
    expect(page.documents[page.activeDocId]!.text, work);
    expect(_closeCross('main.js'), findsNothing);
    expect(find.byKey(const ValueKey('conflict_dialog')), findsNothing);

    // Unsaved edits to app.py; app.py changes on disk while the app is
    // dead.
    await tester.tap(find.byKey(const ValueKey('tree_app.py')));
    await tester.pumpAndSettle();
    page.typeText('# mine\n');
    await tester.pumpAndSettle();
    final mine = page.documents[page.activeDocId]!.text;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
    harness.files.putText('app.py', 'print("theirs")\n');
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('conflict_dialog')), findsOneWidget);
    expect(find.text('app.py changed on disk'), findsOneWidget);
    expect(_state(tester).activePath, 'app.py');
    await tester.tap(find.byKey(const ValueKey('conflict_keep')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conflict_dialog')), findsNothing);
    final app = _state(tester).documents['app.py']!;
    expect(app.conflict, isNull);
    expect(app.dirty, isTrue);
    expect(app.savedText, 'print("theirs")\n');
    page = harness.editorSurface;
    expect(page.documents[app.docId]!.text, mine);
    expect(_state(tester).documents['main.js']!.dirty, isTrue);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a large file opens as plain text under a banner (W7)', (
    tester,
  ) async {
    await _pumpWorkbench(
      tester,
      before: (harness) {
        harness.files
          ..putText('big.js', 'x' * (plainTextAboveChars + 1))
          ..putText('big.py', 'x' * (plainTextAboveChars + 1));
      },
    );
    final banner = find.byKey(const ValueKey('large_file_notice'));
    Finder language(String label) => find.descendant(
      of: find.byKey(const ValueKey('status_language')),
      matching: find.text(label),
    );
    expect(banner, findsNothing, reason: 'main.js');

    await tester.tap(find.byKey(const ValueKey('tree_big.js')));
    await tester.pumpAndSettle();
    expect(banner, findsOneWidget);
    expect(language('plaintext'), findsOneWidget);
    // The banner belongs to its document: another tab has none.
    await tester.tap(_tabText('main.js'));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    await tester.tap(_tabText('big.js'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Highlight anyway'));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(language('javascript'), findsOneWidget);
    expect(_state(tester).documents['big.js']!.largeFile, isFalse);

    // Dismissed, the banner goes and the document stays plain text.
    await tester.tap(find.byKey(const ValueKey('tree_big.py')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: banner, matching: find.byIcon(Icons.close)),
    );
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(language('plaintext'), findsOneWidget);
  });

  testWidgets('the editor says when unsaved changes are not backed up', (
    tester,
  ) async {
    final sessions = FlakySessionStore();
    setSurface(tester, 1280, 800);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
      sessionStore: sessions,
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    final banner = find.byKey(const ValueKey('journal_problem'));
    expect(banner, findsNothing);

    sessions.failing = true;
    harness.editorSurface.typeText('x');
    await tester.pumpAndSettle();
    expect(banner, findsOneWidget);

    sessions.failing = false;
    harness.editorSurface.typeText('y');
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('rotating keeps the page, the unsaved text, the dirty dot and '
      'the cursor (G4)', (tester) async {
    setSurface(tester, 360, 800);
    final harness = TestHarness(
      shell: const ShellState(lastRoute: '/workspace'),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    expect(_state(tester).activePath, 'main.js');
    final docId = _state(tester).active!.docId;
    harness.editorSurface
      ..typeText('// typed in portrait\n')
      ..moveCursor(3, head: 8);
    await tester.pumpAndSettle();
    final text = harness.editorSurface.documents[docId]!.text;
    expect(_closeCross('main.js'), findsNothing, reason: 'dirty: a dot');

    // Portrait → landscape swaps the compact layout for the docked one;
    // the editor pane moves across rather than being rebuilt.
    for (final size in const [Size(800, 360), Size(360, 800)]) {
      setSurface(tester, size.width, size.height);
      await tester.pumpAndSettle();
      final page = harness.editorSurface;
      final doc = page.documents[docId]!;
      final at = '${size.width.round()}x${size.height.round()}';
      expect(doc.text, text, reason: at);
      expect([doc.anchor, doc.head], [3, 8], reason: at);
      expect(_state(tester).active!.dirty, isTrue, reason: at);
      expect(harness.editorSurfaces, hasLength(1), reason: '$at: same page');
      expect(page.loads, 1, reason: '$at: never reloaded');
    }
    expect(_closeCross('main.js'), findsNothing);
    expect(_container(tester).read(editorHostProvider).textOf(docId), text);
    await tester.pump(const Duration(seconds: 2));
  });
}
