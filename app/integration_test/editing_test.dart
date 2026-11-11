/// Phase 2 W6 on the CI emulator (gate G5): find, replace and go to line on
/// the real editor page in the Android System WebView, through the real
/// find bar and go-to-line dialog. Widget tests drive the same widgets
/// against a scripted page; this proves CodeMirror's counts, whole-word and
/// regular-expression matching, replacement groups, one-step undo of a
/// replace all, and the cursor landing where go to line sends it.
library;

import 'package:codeforge/app.dart';
import 'package:codeforge/application/commands.dart';
import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/editor/find_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/core/errors/failure.dart';
import 'package:codeforge/services/contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'smoke_test.dart' show pumpRealApp, pumpUntil;

/// Six `value`s: one inside `values`, one capitalised.
const String _source =
    'value = 1\nvalues = [value, Value]\nprint(value)  # value\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('editing: find, replace and go to line on the real page', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await pumpRealApp(tester, prefs);
    await tester.tap(find.byKey(const ValueKey('welcome_dismiss')));
    await tester.pumpAndSettle();
    // Home's list may need to scroll to it (Phase 3 W3).
    await tester.ensureVisible(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('explore_demo')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CodeForgeApp)),
      listen: false,
    );
    final host = container.read(editorHostProvider);
    await pumpUntil(
      tester,
      () =>
          host.status.phase == EditorHostPhase.ready ||
          host.status.phase == EditorHostPhase.failed,
      what: 'the editor page to start',
    );
    expect(
      host.status.phase,
      EditorHostPhase.ready,
      reason: host.status.message,
    );
    await pumpUntil(tester, () => host.syncs >= 1, what: 'the first sync');

    // Languages come from the extension, or from the shebang line.
    final files = container.read(fileServiceProvider);
    final documents = container.read(documentControllerProvider.notifier);
    for (final (path, text) in [
      ('g5/tool', '#!/usr/bin/env python3\nprint("hi")\n'),
      ('g5/find.py', _source),
    ]) {
      final written = await files.writeText(
        path,
        text,
        mode: WriteMode.createNew,
      );
      expect(written.isOk, isTrue, reason: path);
      expect((await documents.open(path)).isOk, isTrue, reason: path);
    }
    await tester.pumpAndSettle();
    final opened = container.read(documentControllerProvider).documents;
    expect(opened['g5/tool']!.language, 'python');
    expect(opened['g5/find.py']!.language, 'python');
    final docId = opened['g5/find.py']!.docId;

    final findBar = container.read(findControllerProvider.notifier);
    FindState state() => container.read(findControllerProvider);
    // Waits for the bar's count; a timeout says what it showed instead.
    Future<void> showsCount(String summary) async {
      final watch = Stopwatch()..start();
      while (state().summary != summary) {
        if (watch.elapsed > const Duration(seconds: 30)) {
          fail('The find bar says "${state().summary}", not "$summary".');
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> tapKey(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
    }

    // CodeMirror counts, and the options narrow what it counts.
    await findBar.open(replace: true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find_bar')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('find_query')), 'value');
    await showsCount('6 results');
    await tapKey('find_case');
    await showsCount('5 results');
    await tapKey('find_word');
    await showsCount('4 results');

    // Stepping selects each match in turn.
    await tapKey('find_next');
    await showsCount('1 of 4');
    await tapKey('find_next');
    await showsCount('2 of 4');
    // `[value` on line 2: line 1 and its break are 10 characters.
    await pumpUntil(
      tester,
      () => host.viewStateOf(docId)?.selection?.anchor == 20,
      what: 'the second match to be selected',
    );

    // Replace all changes whole words only, and is one undo step.
    await tester.enterText(
      find.byKey(const ValueKey('find_replacement')),
      'amount',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tapKey('find_replace_all');
    const replaced =
        'amount = 1\nvalues = [amount, Value]\nprint(amount)  # amount\n';
    await pumpUntil(
      tester,
      () => host.textOf(docId) == replaced,
      what: 'replace all to reach the shadow',
    );
    await showsCount('No results');
    final registry = container.read(commandRegistryProvider);
    void run(String id) =>
        registry.commands.firstWhere((c) => c.id == id).onExecute();
    run('edit.undo');
    await pumpUntil(
      tester,
      () => host.textOf(docId) == _source,
      what: 'one undo to bring every match back',
    );
    run('edit.redo');
    await pumpUntil(
      tester,
      () => host.textOf(docId) == replaced,
      what: 'redo to replace them again',
    );

    // Regular expressions, with groups in the replacement.
    await tapKey('find_word');
    await tapKey('find_regex');
    await tester.enterText(find.byKey(const ValueKey('find_query')), '(');
    await showsCount('Invalid pattern');
    await tester.enterText(
      find.byKey(const ValueKey('find_query')),
      r'(\w+) = (\d+)',
    );
    await tester.enterText(
      find.byKey(const ValueKey('find_replacement')),
      r'$2 = $1',
    );
    // Line 1 only; "1 of 1" if the selection happens to be on it.
    await pumpUntil(
      tester,
      () => state().valid && state().matches == 1,
      what: 'one match for the pattern',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tapKey('find_replace_all');
    const swapped =
        '1 = amount\nvalues = [amount, Value]\nprint(amount)  # amount\n';
    await pumpUntil(
      tester,
      () => host.textOf(docId) == swapped,
      what: r'the $2 = $1 replacement',
    );

    await tapKey('find_close');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find_bar')), findsNothing);

    // Go to line 3, column 7: the cursor lands there. The dialog follows a
    // flush of the real page, a round trip pumpAndSettle does not wait for
    // (gate 42399401256 looked for it too early).
    run('edit.gotoLine');
    final dialog = find.byKey(const ValueKey('goto_line_dialog'));
    await pumpUntil(
      tester,
      () => dialog.evaluate().isNotEmpty,
      what: 'the go-to-line dialog',
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('goto_line_field')),
      '3:7',
    );
    await tester.tap(find.byKey(const ValueKey('goto_line_confirm')));
    await tester.pumpAndSettle();
    final line3 = swapped.indexOf('print(');
    await pumpUntil(
      tester,
      () => host.viewStateOf(docId)?.selection?.head == line3 + 6,
      what: 'the cursor to reach line 3, column 7',
    );

    expect(host.droppedMessages, 0);
    expect(host.resyncs, 0);
    debugPrint(
      'editing: ok (counts 6/5/4 by option, a whole-word replace all undone '
      'in one step, \$2 = \$1 groups, cursor at ${line3 + 6} = line 3 '
      'column 7; page starts ${host.pageStarts}, syncs ${host.syncs}, '
      'resyncs ${host.resyncs})',
    );
  });
}
