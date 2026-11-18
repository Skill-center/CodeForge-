import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/core/search/search_models.dart';
import 'package:codeforge/design_system/tokens/colors.dart';
import 'package:codeforge/features/workbench/panels/search_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_search_service.dart';
import 'test_harness.dart';

/// The Search panel (Phase 4 W6, gate G8) in the real workbench, over a
/// scripted search host.
void main() {
  Future<TestHarness> openSearch(WidgetTester tester) async {
    setSurface(tester, 1280, 800);
    final harness = TestHarness();
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    await openDemoWorkspace(tester);
    await tester.tap(find.byKey(const ValueKey('activity_search')));
    await tester.pumpAndSettle();
    return harness;
  }

  Future<void> searchFor(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('search_query')), text);
    await tester.tap(find.byKey(const ValueKey('search_go')));
    await tester.pumpAndSettle();
  }

  String status(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('search_status')))
      .data!;

  testWidgets('results come grouped by file, and one opens at its line', (
    tester,
  ) async {
    final harness = await openSearch(tester);
    await searchFor(tester, 'greet');
    expect(status(tester), 'Searching…');
    final run = harness.search.last;
    expect(run.query.text, 'greet');
    expect(run.query.caseSensitive, isFalse);

    run.found([
      searchFile('main.js', [(2, "import { greet } from './utils.js';", 'greet')]),
      searchFile('utils.js', [
        (2, 'export function greet(language) {', 'greet'),
      ]),
    ]);
    run.finish(SearchOutcome.done, filesSearched: 8);
    await tester.pumpAndSettle();
    expect(status(tester), '2 results in 2 files');
    expect(find.byKey(const ValueKey('search_file_main.js')), findsOneWidget);
    expect(find.byKey(const ValueKey('search_file_utils.js')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search_line_utils.js:2')));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SearchPanel)),
    );
    expect(container.read(documentControllerProvider).activePath, 'utils.js');
    expect(harness.editorSurface.gotoLines.last, (line: 2, column: 17));
  });

  testWidgets('a file folds its lines away, and back', (tester) async {
    final harness = await openSearch(tester);
    await searchFor(tester, 'greet');
    harness.search.last.found([
      searchFile('utils.js', [
        (2, 'export function greet(language) {', 'greet'),
      ]),
    ]);
    harness.search.last.finish(SearchOutcome.done);
    await tester.pumpAndSettle();
    final line = find.byKey(const ValueKey('search_line_utils.js:2'));
    expect(line, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search_file_utils.js')));
    await tester.pumpAndSettle();
    expect(line, findsNothing);
    await tester.tap(find.byKey(const ValueKey('search_file_utils.js')));
    await tester.pumpAndSettle();
    expect(line, findsOneWidget);
  });

  testWidgets('stop keeps what was found and says so', (tester) async {
    final harness = await openSearch(tester);
    await searchFor(tester, 'a');
    harness.search.last.found([
      searchFile('main.js', [(5, 'const languages = [];', 'a')]),
    ]);
    await tester.pumpAndSettle();
    expect(status(tester), 'Searching… 1 result in 1 file');
    await tester.tap(find.byKey(const ValueKey('search_stop')));
    await tester.pumpAndSettle();
    expect(harness.search.last.cancelRequested, isTrue);
    expect(status(tester), 'Stopped: 1 result in 1 file so far');
    expect(find.byKey(const ValueKey('search_file_main.js')), findsOneWidget);
  });

  testWidgets('the switches and the globs reach the search, and a switch runs it again', (
    tester,
  ) async {
    final harness = await openSearch(tester);
    await tester.tap(find.byKey(const ValueKey('search_filters')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('search_includes')),
      'src, *.js',
    );
    await tester.enterText(
      find.byKey(const ValueKey('search_excludes')),
      'dist',
    );
    await tester.tap(find.byKey(const ValueKey('search_word')));
    await tester.pumpAndSettle();
    // No search has run yet: a switch alone starts none.
    expect(harness.search.runs, isEmpty);

    await searchFor(tester, 'lang');
    var run = harness.search.last;
    expect(run.query.wholeWord, isTrue);
    expect(run.query.includes, ['src', '*.js']);
    expect(run.query.excludes, ['dist']);

    await tester.tap(find.byKey(const ValueKey('search_case')));
    await tester.pumpAndSettle();
    expect(harness.search.runs, hasLength(2));
    run = harness.search.last;
    expect(run.query.caseSensitive, isTrue);
    expect(harness.search.runs.first.finished, isTrue);
  });

  testWidgets('a pattern that cannot run says why', (tester) async {
    final harness = await openSearch(tester);
    await tester.tap(find.byKey(const ValueKey('search_regex')));
    await tester.pumpAndSettle();
    await searchFor(tester, '(?<=a)b');
    harness.search.last.finish(
      SearchOutcome.failed,
      problem: SearchProblem.badQuery,
      detail: 'Not a valid regular expression for ripgrep: look-around is '
          'not supported',
    );
    await tester.pumpAndSettle();
    expect(status(tester), contains('look-around is not supported'));
  });

  testWidgets('nothing found says how much was searched, and what was left out', (
    tester,
  ) async {
    final harness = await openSearch(tester);
    await searchFor(tester, 'zzz');
    harness.search.last.finish(SearchOutcome.done, filesSearched: 1234);
    await tester.pumpAndSettle();
    expect(status(tester), 'No results in 1,234 files');
  });

  testWidgets('before any search, the panel says what it does', (
    tester,
  ) async {
    await tester.pumpWidget(
      TestHarness().wrap(const Scaffold(body: SearchPanel())),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Go to File… in the command palette'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search_status')), findsNothing);
  });

  test('a long line shows an ellipsis where it was cut, and its matches', () {
    const line = SearchLine(
      line: 9,
      column: 120,
      preview: 'abc match def',
      previewStart: 80,
      cutEnd: true,
      ranges: [4, 9],
    );
    final (spans, plain) = previewSpans(
      line,
      const TextStyle(),
      CfColors.dark,
    );
    expect(plain, '…abc match def…');
    expect(spans.map((s) => s.text), ['…', 'abc ', 'match', ' def', '…']);
  });
}
