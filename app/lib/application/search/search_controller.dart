/// The Search panel's state (Phase 4 W6): the last query, the files found so
/// far grouped by file, and how the search ended. Searching goes through the
/// search service (services/search/search_service.dart), over the open
/// workspace; switching workspaces drops the results.
///
/// - **One search at a time:** a new query cancels the running search, and
///   its late results are ignored.
/// - **Stop** keeps what was found and waits for the host's summary, so the
///   counts are the host's.
/// - **Timing** (the panel's figures, and the gate's): from the moment the
///   search was asked for to its first file with a match, and to its end,
///   measured here, on the UI isolate, as the user sees it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger.dart';
import '../../core/search/search_models.dart';
import '../../services/search/search_service.dart';
import '../providers.dart';

/// Where a search is.
enum SearchPhase {
  /// No search yet, or the query was cleared.
  idle,
  running,

  /// Stop was asked for; the host's summary has not come yet.
  stopping,
  finished,
}

final class SearchState {
  const SearchState({
    this.query = const SearchQuery(text: ''),
    this.phase = SearchPhase.idle,
    this.files = const [],
    this.lines = 0,
    this.matches = 0,
    this.summary,
    this.collapsed = const {},
    this.firstResultMs,
    this.elapsedMs,
  });

  /// The query of the results shown.
  final SearchQuery query;

  final SearchPhase phase;

  /// Files with matches, in the order they were found.
  final List<SearchFileResult> files;

  /// Matching lines and matches in [files].
  final int lines;
  final int matches;

  /// How the search ended; null until it has.
  final SearchSummary? summary;

  /// Files whose lines are folded away, by path.
  final Set<String> collapsed;

  /// From asking to the first file with a match, as the panel saw it.
  final int? firstResultMs;

  /// From asking to the end, as the panel saw it.
  final int? elapsedMs;

  bool get busy =>
      phase == SearchPhase.running || phase == SearchPhase.stopping;

  SearchState copyWith({
    SearchPhase? phase,
    List<SearchFileResult>? files,
    int? lines,
    int? matches,
    SearchSummary? summary,
    Set<String>? collapsed,
    int? firstResultMs,
    int? elapsedMs,
  }) => SearchState(
    query: query,
    phase: phase ?? this.phase,
    files: files ?? this.files,
    lines: lines ?? this.lines,
    matches: matches ?? this.matches,
    summary: summary ?? this.summary,
    collapsed: collapsed ?? this.collapsed,
    firstResultMs: firstResultMs ?? this.firstResultMs,
    elapsedMs: elapsedMs ?? this.elapsedMs,
  );
}

final class SearchController extends Notifier<SearchState> {
  SearchRun? _run;
  StreamSubscription<SearchUpdate>? _subscription;
  Stopwatch _watch = Stopwatch();

  @override
  SearchState build() {
    ref.watch(currentWorkspaceProvider);
    ref.onDispose(_drop);
    return const SearchState();
  }

  /// Searches the open workspace for [query]. An empty text clears the
  /// results instead.
  void search(SearchQuery query, {int? maxResults}) {
    _drop();
    if (query.text.isEmpty) {
      state = SearchState(query: query);
      return;
    }
    _watch = Stopwatch()..start();
    state = SearchState(query: query, phase: SearchPhase.running);
    final run = ref
        .read(searchServiceProvider)
        .start(
          ref.read(currentWorkspaceProvider),
          query,
          maxResults: maxResults,
        );
    _run = run;
    _subscription = run.updates.listen(
      (update) => _take(run, update),
      onError: (Object error) => _take(
        run,
        SearchFinished(
          SearchSummary.failed(SearchProblem.failed, error.toString()),
        ),
      ),
    );
  }

  /// Stops the running search; what it found stays.
  Future<void> stop() async {
    final run = _run;
    if (run == null || state.phase != SearchPhase.running) {
      return;
    }
    state = state.copyWith(phase: SearchPhase.stopping);
    await run.cancel();
  }

  /// Folds [path]'s lines away, or shows them again.
  void toggleCollapsed(String path) {
    final collapsed = {...state.collapsed};
    if (!collapsed.remove(path)) {
      collapsed.add(path);
    }
    state = state.copyWith(collapsed: collapsed);
  }

  /// Clears the results, stopping a search that runs.
  void clear() {
    _drop();
    state = SearchState(query: state.query.copyWith(text: ''));
  }

  void _take(SearchRun run, SearchUpdate update) {
    if (!identical(run, _run)) {
      return;
    }
    switch (update) {
      case SearchFound(:final files):
        if (files.isEmpty) {
          return;
        }
        var lines = state.lines;
        var matches = state.matches;
        for (final file in files) {
          lines += file.lines.length;
          matches += file.matches;
        }
        state = state.copyWith(
          files: [...state.files, ...files],
          lines: lines,
          matches: matches,
          firstResultMs: state.firstResultMs ?? _watch.elapsedMilliseconds,
        );
      case SearchFinished(:final summary):
        _watch.stop();
        _run = null;
        _subscription = null;
        state = state.copyWith(
          phase: SearchPhase.finished,
          summary: summary,
          elapsedMs: _watch.elapsedMilliseconds,
        );
        appLogger.info(
          'search',
          'finished',
          fields: {
            'engine': summary.engine.name,
            'outcome': summary.outcome.name,
            'files': summary.filesSearched,
            'matched': summary.filesMatched,
            'lines': summary.lines,
            'firstMs': state.firstResultMs ?? -1,
            'ms': state.elapsedMs ?? -1,
          },
        );
    }
  }

  /// Lets go of the running search: cancelled on the host if it still runs.
  void _drop() {
    final run = _run;
    _run = null;
    if (run != null) {
      unawaited(run.cancel());
    }
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}

final searchControllerProvider =
    NotifierProvider<SearchController, SearchState>(SearchController.new);
