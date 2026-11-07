/// FindController (Phase 2 W6): the find bar's session over the scripted
/// editor page. Opening seeds the query from the selection, counts come
/// from the page's `search.state`, and the session follows tabs and
/// survives a page restart. Plain tests in real time.
library;

import 'package:codeforge/application/documents/document_controller.dart';
import 'package:codeforge/application/editor/editor_host.dart';
import 'package:codeforge/application/editor/editor_providers.dart';
import 'package:codeforge/application/editor/find_controller.dart';
import 'package:codeforge/application/providers.dart';
import 'package:codeforge/services/settings/settings_store.dart';
import 'package:codeforge/services/shell/shell_state.dart';
import 'package:codeforge/services/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_editor_surface.dart';
import '../support/memory_file_service.dart';

const Map<String, String> _files = {
  'a.txt': 'one two one\nthree one',
  'b.txt': 'one',
};

final class _World {
  _World() {
    container = ProviderContainer.test(
      overrides: [
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        shellStateStoreProvider.overrideWithValue(InMemoryShellStateStore()),
        fileServiceProvider.overrideWithValue(MemoryFileService(seed: _files)),
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        ...fakeEditorOverrides(pages.add),
      ],
    );
  }

  final List<FakeEditorSurface> pages = [];
  late final ProviderContainer container;

  FakeEditorSurface get page => pages.single;
  EditorHost get host => container.read(editorHostProvider);
  FindController get find => container.read(findControllerProvider.notifier);
  FindState get state => container.read(findControllerProvider);
  DocumentController get documents =>
      container.read(documentControllerProvider.notifier);

  /// Starts the page and opens [paths]; the last one is active.
  Future<void> start(List<String> paths) async {
    container.read(findControllerProvider);
    await host.start();
    await _drain();
    for (final path in paths) {
      await documents.open(path);
    }
    await _drain();
  }

  /// The page's text of [path].
  String text(String path) {
    final doc = container.read(documentControllerProvider).documents[path]!;
    return page.documents[doc.docId]!.text;
  }
}

/// Lets streams and microtasks run.
Future<void> _drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('opens with the selected word and shows its count', () async {
    final w = _World();
    await w.start(['a.txt']);
    w.page.moveCursor(4, head: 7);
    await _drain();
    await w.find.open();
    await _drain();
    expect(w.state.open, isTrue);
    expect(w.state.query, 'two');
    expect(w.page.searchSpec?['query'], 'two');
    expect((w.state.matches, w.state.current), (1, 1));
    expect(w.state.summary, '1 of 1');
  });

  test('does not seed from a selection across lines', () async {
    final w = _World();
    await w.start(['a.txt']);
    w.page.moveCursor(0, head: 15);
    await _drain();
    await w.find.open();
    expect(w.state.query, '');
    expect(w.state.summary, '');
  });

  test('steps through the matches, wrapping at both ends', () async {
    final w = _World();
    await w.start(['a.txt']);
    await w.find.open();
    w.find.setQuery('one');
    await _drain();
    expect((w.state.matches, w.state.current), (3, 0));
    expect(w.state.summary, '3 results');
    final currents = <int>[];
    for (final step in [w.find.next, w.find.next, w.find.next, w.find.next]) {
      await step();
      await _drain();
      currents.add(w.state.current);
    }
    await w.find.previous();
    await _drain();
    currents.add(w.state.current);
    expect(currents, [1, 2, 3, 1, 3]);
    expect(w.state.summary, '3 of 3');
  });

  test('replaces one match, then all, through the page', () async {
    final w = _World();
    await w.start(['a.txt']);
    await w.find.open(replace: true);
    expect(w.state.replaceOpen, isTrue);
    w.find
      ..setQuery('one')
      ..setReplacement('1');
    await _drain();
    // The first press selects a match; the second replaces it.
    await w.find.replaceOne();
    await w.find.replaceOne();
    await _drain();
    expect(w.text('a.txt'), '1 two one\nthree one');
    expect((w.state.matches, w.state.current), (2, 1));
    await w.find.replaceAll();
    await _drain();
    expect(w.text('a.txt'), '1 two 1\nthree 1');
    expect(w.state.summary, 'No results');
    final doc = w.container.read(documentControllerProvider).documents;
    expect(doc['a.txt']!.dirty, isTrue);
  });

  test('sends the options; a broken pattern runs nothing', () async {
    final w = _World();
    await w.start(['a.txt']);
    await w.find.open();
    w.find
      ..toggleCaseSensitive()
      ..toggleWholeWord()
      ..toggleRegexp()
      ..setQuery('(');
    await _drain();
    expect(w.page.searchSpec, containsPair('caseSensitive', true));
    expect(w.page.searchSpec, containsPair('wholeWord', true));
    expect(w.page.searchSpec, containsPair('regexp', true));
    expect(w.state.valid, isFalse);
    expect(w.state.summary, 'Invalid pattern');
    final sent = w.page.commands.length;
    await w.find.next();
    await w.find.replaceAll();
    expect(w.page.commands, hasLength(sent));
  });

  test('closes from the bar, giving the editor the keyboard', () async {
    final w = _World();
    await w.start(['a.txt']);
    await w.find.open();
    w.find.setQuery('one');
    await _drain();
    await w.find.close(refocusEditor: true);
    await _drain();
    expect(w.state.open, isFalse);
    expect(w.state.query, 'one');
    expect(w.page.searchSpec, isNull);
    expect(w.page.commands.sublist(w.page.commands.length - 2), [
      'closeSearch',
      'focus',
    ]);
  });

  test('closes when Escape ends the search in the editor', () async {
    final w = _World();
    await w.start(['a.txt']);
    await w.find.open();
    w.find.setQuery('one');
    await _drain();
    w.page.pressEscapeInEditor();
    await _drain();
    expect(w.state.open, isFalse);
  });

  test('shows the count of whichever document is active', () async {
    final w = _World();
    await w.start(['a.txt', 'b.txt']);
    await w.find.open();
    w.find.setQuery('one');
    await _drain();
    expect(w.state.matches, 1);
    w.documents.activate('a.txt');
    await _drain();
    expect(w.state.matches, 3);
  });

  test('sends the session again to a restarted page', () async {
    final w = _World();
    await w.start(['a.txt']);
    await w.find.open();
    w.find.setQuery('three');
    await _drain();
    w.page.restartPage();
    expect(w.page.searchSpec, isNull);
    await _drain();
    expect(w.host.syncs, greaterThanOrEqualTo(2));
    expect(w.page.searchSpec?['query'], 'three');
    expect((w.state.open, w.state.matches), (true, 1));
  });

  test('ignores reports about documents out of view', () async {
    final w = _World();
    await w.start(['a.txt']);
    await w.find.open();
    w.find.setQuery('one');
    await _drain();
    w.page.emit('search.state', {
      'docId': 'elsewhere',
      'open': false,
      'valid': true,
      'matches': 0,
      'current': 0,
      'capped': false,
    });
    await _drain();
    expect((w.state.open, w.state.matches), (true, 3));
  });

  group('summary', () {
    FindState counted(int matches, int current, {bool capped = false}) =>
        FindState(
          open: true,
          query: 'x',
          valid: true,
          matches: matches,
          current: current,
          capped: capped,
        );

    test('words the count for the bar', () {
      expect(const FindState().summary, '');
      expect(counted(0, 0).summary, 'No results');
      expect(counted(1, 0).summary, '1 result');
      expect(counted(12, 0).summary, '12 results');
      expect(counted(12, 3).summary, '3 of 12');
      expect(counted(1000, 0, capped: true).summary, '1000+ results');
      expect(counted(1000, 5, capped: true).summary, '5 of 1000+');
    });

    test('names a broken pattern only in regular expression mode', () {
      const broken = FindState(open: true, query: '(', regexp: true);
      expect(broken.summary, 'Invalid pattern');
      expect(broken.copyWith(regexp: false).summary, '');
    });
  });
}
