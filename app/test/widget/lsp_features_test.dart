/// The language features in the workbench (Phase 6 W5, PHASE_6_PLAN W5):
/// the problems chip counts the active file's problems and opens the
/// Problems sheet, whose rows go to their place; the rename dialog starts
/// from the server's name, refuses an empty or unchanged one, renames and
/// sums up; a definition in a server's own file opens read-only; the
/// symbol toolbar's definition key asks the page; and Settings → Editor
/// turns a language's server off.
library;

import 'package:codeforge/application/workbench_intents.dart';
import 'package:codeforge/core/lsp/lsp_models.dart';
import 'package:codeforge/design_system/components/feedback.dart';
import 'package:codeforge/design_system/tokens/icons.dart';
import 'package:codeforge/features/workbench/workbench_screen.dart';
import 'package:codeforge/services/settings/settings_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../support/memory_library_files.dart';
import 'lsp_workbench.dart';

Map<String, Object?> _problem(int line, int from, int to, int severity) =>
    lspProblem(line, from, to, severity);

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(WorkbenchScreen)),
  listen: false,
);

CfStatusChip _chip(WidgetTester tester) =>
    tester.widget<CfStatusChip>(find.byKey(const ValueKey('status_problems')));

void main() {
  testWidgets("the problems chip counts the file's problems, the worst "
      'first, and the sheet goes to each', (tester) async {
    final (harness, lsp) = await pumpWithServers(
      tester,
      files: {'greet.py': 'import os\nprint(greet)\n'},
    );
    await openFile(tester, 'greet.py');
    expect(_chip(tester).label, '0');
    expect(_chip(tester).icon, CfIcons.check);

    await publish(tester, lsp, 'greet.py', [
      _problem(1, 6, 11, 1),
      _problem(0, 7, 9, 2),
    ]);
    expect(_chip(tester).label, '2');
    expect(_chip(tester).icon, CfIcons.error);
    expect(
      _chip(tester).tooltip,
      '1 error, 1 warning in this file. Tap to see the problems.',
    );
    // The page draws them too.
    expect(harness.editorSurface.diagnostics.values.single.items, hasLength(2));

    await tester.tap(find.byKey(const ValueKey('status_problems')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('problems_sheet')), findsOneWidget);
    expect(find.text('Problems: 1 error, 1 warning'), findsOneWidget);
    // By line: the warning on line 1 first, then the error on line 2.
    await tester.tap(find.byKey(const ValueKey('problem_greet.py_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('problems_sheet')), findsNothing);
    expect(harness.editorSurface.gotoLines.last, (line: 2, column: 7));

    // Fixed: cleared everywhere.
    await publish(tester, lsp, 'greet.py', []);
    expect(_chip(tester).label, '0');
    expect(harness.editorSurface.diagnostics.values.single.items, isEmpty);
  });

  testWidgets('the Problems sheet opens from the page shortcut, and says '
      'when there are none', (tester) async {
    final (harness, _) = await pumpWithServers(tester);
    harness.editorSurface.pressShortcut('problems');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('problems_empty')), findsOneWidget);
    expect(find.text('No problems in the open files.'), findsOneWidget);
  });

  testWidgets("rename: the dialog starts from the server's name, refuses "
      'an empty or unchanged one, renames, and sums up', (tester) async {
    final (harness, lsp) = await pumpWithServers(
      tester,
      files: {'greet.py': 'def greet():\n    pass\n\ngreet()\n'},
    );
    lsp.answerWith({
      'textDocument/prepareRename': (_) => {
        'range': lspRange(0, 4, 0, 9),
        'placeholder': 'greet',
      },
      'textDocument/rename': (params) => {
        'changes': {
          'file://$lspDemoRoot/greet.py': [
            for (final (line, from) in [(0, 4), (3, 0)])
              {
                'range': lspRange(line, from, line, from + 5),
                'newText': (params! as Map<String, Object?>)['newName'],
              },
          ],
        },
      },
    });
    await openFile(tester, 'greet.py');
    await pageAsks(tester, harness, 'lsp.prepareRename', 5);
    expect(find.byKey(const ValueKey('rename_dialog')), findsOneWidget);
    expect(find.text('Rename greet'), findsOneWidget);
    final field = find.byKey(const ValueKey('rename_field'));
    expect(tester.widget<TextField>(field).controller!.text, 'greet');

    await tester.tap(find.byKey(const ValueKey('rename_confirm')));
    await tester.pumpAndSettle();
    expect(find.text('That is its name now.'), findsOneWidget);
    await tester.enterText(field, '   ');
    await tester.tap(find.byKey(const ValueKey('rename_confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Type the new name.'), findsOneWidget);
    await tester.enterText(field, 'welcome');
    await tester.tap(find.byKey(const ValueKey('rename_confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('rename_dialog')), findsNothing);
    final page = harness.editorSurface;
    expect(
      page.documents[page.activeDocId]!.text,
      'def welcome():\n    pass\n\nwelcome()\n',
    );
    expect(
      find.text('Renamed greet to welcome in 1 file: greet.py'),
      findsOneWidget,
    );
    // Cancelling changes nothing.
    await pageAsks(tester, harness, 'lsp.prepareRename', 5);
    await tester.tap(find.byKey(const ValueKey('rename_cancel')));
    await tester.pumpAndSettle();
    expect(page.undoStack[page.activeDocId], hasLength(1));
  });

  testWidgets("a definition in a server's own file opens read-only, at the "
      'place', (tester) async {
    final library = MemoryLibraryFiles()
      ..files[lspStub] = [for (var i = 0; i < 60; i++) 'def f$i(): ...'].join(
        '\n',
      );
    final (harness, lsp) = await pumpWithServers(
      tester,
      files: {'use.py': 'f40()\n'},
      library: library,
    );
    lsp.answerWith({
      'textDocument/definition': (_) => {
        'uri': 'file://$lspStub',
        'range': lspRange(40, 4, 40, 7),
      },
    });
    await openFile(tester, 'use.py');
    await pageAsks(tester, harness, 'lsp.definition', 1);
    expect(find.byKey(const ValueKey('library_file_sheet')), findsOneWidget);
    expect(find.text('builtins.pyi, line 41'), findsOneWidget);
    expect(
      find.text('Python stubs: stdlib/builtins.pyi · read-only'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('library_file_target')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library_file_close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library_file_sheet')), findsNothing);
  });

  testWidgets("the toolbar's definition key asks the page, for a language a "
      'server analyses only', (tester) async {
    final (harness, _) = await pumpWithServers(
      tester,
      files: {'use.py': 'x\n', 'style.css': 'a {}\n'},
      settings: const AppSettings(welcomeSeen: true, toolbarKeys: '()'),
    );
    await openFile(tester, 'use.py');
    harness.editorSurface.emit('editor.focus', {'focused': true});
    await tester.pumpAndSettle();
    final key = find.byKey(const ValueKey('toolbar_definition'));
    expect(key, findsOneWidget);
    await tester.tap(key);
    await tester.pumpAndSettle();
    expect(harness.editorSurface.commands.last, 'goToDefinition');

    await openFile(tester, 'style.css');
    expect(find.byKey(const ValueKey('toolbar_definition')), findsNothing);
  });

  testWidgets('the palette asks the page for definition, rename and hover', (
    tester,
  ) async {
    final (harness, _) = await pumpWithServers(tester, files: {'use.py': 'x\n'});
    await openFile(tester, 'use.py');
    final intents = _container(tester).read(workbenchIntentsProvider);
    for (final intent in [
      WorkbenchIntent.goToDefinition,
      WorkbenchIntent.renameSymbol,
      WorkbenchIntent.showHover,
    ]) {
      intents.fire(intent);
      await tester.pumpAndSettle();
    }
    expect(harness.editorSurface.commands.skip(
      harness.editorSurface.commands.length - 3,
    ), ['goToDefinition', 'renameSymbol', 'showHover']);
  });

  testWidgets("Settings → Editor turns a language's server off", (
    tester,
  ) async {
    final (harness, lsp) = await pumpWithServers(
      tester,
      files: {'use.py': 'x\n'},
    );
    await openFile(tester, 'use.py');
    expect(find.byKey(const ValueKey('status_lsp')), findsOneWidget);
    GoRouter.of(tester.element(find.byType(WorkbenchScreen))).go(
      '/settings/editor',
    );
    await tester.pumpAndSettle();
    expect(find.text('pyright 1.1.414'), findsOneWidget);
    expect(
      find.text('typescript 6.0.3, typescript-language-server 6.1.0'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('settings_server_pyright')));
    await tester.pumpAndSettle();
    expect(harness.settingsStore.load().pythonServer, isFalse);
    expect(harness.settingsStore.load().typescriptServer, isTrue);
    expect(lsp.running.where((h) => h == lsp.handleOf(LspServerId.pyright)),
        isEmpty);
  });
}
