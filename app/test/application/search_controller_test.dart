import 'package:codeforge/application/providers.dart';
import 'package:codeforge/application/search/search_controller.dart';
import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/search/search_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_search_service.dart';

/// The open workspace, switchable by the test.
final class _Workspace extends Notifier<WorkspaceLocation> {
  @override
  WorkspaceLocation build() => const DemoProjectLocation();

  void open(WorkspaceLocation workspace) => state = workspace;
}

final _workspace = NotifierProvider<_Workspace, WorkspaceLocation>(
  _Workspace.new,
);

void main() {
  late FakeSearchService search;
  late ProviderContainer container;

  setUp(() {
    search = FakeSearchService();
    container = ProviderContainer(
      overrides: [
        searchServiceProvider.overrideWithValue(search),
        currentWorkspaceProvider.overrideWith((ref) => ref.watch(_workspace)),
      ],
    );
    addTearDown(container.dispose);
    // Built, as the panel builds it, before the first search.
    container.read(searchControllerProvider);
  });

  SearchController controller() =>
      container.read(searchControllerProvider.notifier);
  SearchState state() => container.read(searchControllerProvider);

  test('results gather by file as they come, then the summary', () async {
    controller().search(const SearchQuery(text: 'greet'));
    expect(state().phase, SearchPhase.running);
    expect(search.last.query.text, 'greet');
    expect(search.last.workspace, const DemoProjectLocation());

    search.last.found([
      searchFile('main.js', [
        (2, "import { greet } from './utils.js';", 'greet'),
      ]),
    ]);
    await pumpEventQueue();
    expect(state().files.single.path, 'main.js');
    expect(state().firstResultMs, isNotNull);

    search.last.found([
      searchFile('utils.js', [
        (2, 'export function greet(language) {', 'greet'),
        (3, '  return greet;', 'greet'),
      ]),
    ]);
    search.last.finish(SearchOutcome.done, filesSearched: 7);
    await pumpEventQueue();
    expect(state().phase, SearchPhase.finished);
    expect(state().files.map((f) => f.path), ['main.js', 'utils.js']);
    expect(state().lines, 3);
    expect(state().matches, 3);
    expect(state().summary!.filesSearched, 7);
    expect(state().elapsedMs, isNotNull);
  });

  test(
    'a new search cancels the running one and ignores its late results',
    () async {
      controller().search(const SearchQuery(text: 'one'));
      final first = search.last;
      controller().search(const SearchQuery(text: 'two'));
      final second = search.last;
      expect(first.cancelRequested, isTrue);

      first.found([
        searchFile('late.js', [(1, 'one', 'one')]),
      ]);
      second.found([
        searchFile('main.js', [(1, 'two', 'two')]),
      ]);
      await pumpEventQueue();
      expect(state().query.text, 'two');
      expect(state().files.map((f) => f.path), ['main.js']);
    },
  );

  test('stop keeps what was found and waits for the host to end', () async {
    controller().search(const SearchQuery(text: 'x'));
    search.last.found([
      searchFile('a.js', [(1, 'x', 'x')]),
    ]);
    await pumpEventQueue();
    await controller().stop();
    await pumpEventQueue();
    expect(search.last.cancelRequested, isTrue);
    expect(state().phase, SearchPhase.finished);
    expect(state().summary!.outcome, SearchOutcome.cancelled);
    expect(state().files.single.path, 'a.js');
  });

  test('an empty query clears the results and starts nothing', () async {
    controller().search(const SearchQuery(text: 'x'));
    expect(search.runs, hasLength(1));
    controller().search(const SearchQuery(text: ''));
    expect(search.runs, hasLength(1));
    expect(search.last.cancelRequested, isTrue);
    expect(state().phase, SearchPhase.idle);
    expect(state().files, isEmpty);
  });

  test(
    'switching workspaces drops the results and the running search',
    () async {
      controller().search(const SearchQuery(text: 'x'));
      search.last.found([
        searchFile('a.js', [(1, 'x', 'x')]),
      ]);
      await pumpEventQueue();
      container
          .read(_workspace.notifier)
          .open(
            const FolderLocation(treeUri: 'content://tree/1', name: 'Gate'),
          );
      expect(state().phase, SearchPhase.idle);
      expect(state().files, isEmpty);
      expect(search.last.cancelRequested, isTrue);

      controller().search(const SearchQuery(text: 'y'));
      expect(search.last.workspace, isA<FolderLocation>());
    },
  );

  test('a file folds away and back', () async {
    controller().search(const SearchQuery(text: 'x'));
    controller().toggleCollapsed('a.js');
    expect(state().collapsed, {'a.js'});
    controller().toggleCollapsed('a.js');
    expect(state().collapsed, isEmpty);
  });
}
