/// A scripted search host (Phase 4 W6): every search is recorded, and the
/// test decides what each finds and how it ends, or lets [results] answer
/// every search at once.
library;

import 'dart:async';

import 'package:codeforge/core/files/workspace_location.dart';
import 'package:codeforge/core/search/search_models.dart';
import 'package:codeforge/services/search/search_service.dart';

final class FakeSearchService implements SearchService {
  /// Every search started, oldest first.
  final List<FakeSearchRun> runs = [];

  /// When set, each search finds these files and ends done, in one
  /// microtask.
  List<SearchFileResult>? results;

  FakeSearchRun get last => runs.last;

  @override
  SearchRun start(
    WorkspaceLocation workspace,
    SearchQuery query, {
    int? maxResults,
  }) {
    // One search at a time, as on the host.
    for (final run in runs) {
      run.finish(SearchOutcome.cancelled);
    }
    final run = FakeSearchRun(workspace, query, maxResults);
    runs.add(run);
    final answer = results;
    if (answer != null) {
      scheduleMicrotask(() {
        run.found(answer);
        run.finish(SearchOutcome.done);
      });
    }
    return run;
  }
}

final class FakeSearchRun implements SearchRun {
  FakeSearchRun(this.workspace, this.query, this.maxResults);

  final WorkspaceLocation workspace;
  final SearchQuery query;
  final int? maxResults;

  final StreamController<SearchUpdate> _updates =
      StreamController<SearchUpdate>();
  final List<SearchFileResult> _found = [];

  /// Whether the summary was sent.
  bool get finished => _updates.isClosed;

  /// Whether the app asked to stop.
  bool cancelRequested = false;

  @override
  Stream<SearchUpdate> get updates => _updates.stream;

  void found(List<SearchFileResult> files) {
    if (finished) {
      return;
    }
    _found.addAll(files);
    _updates.add(SearchFound(files));
  }

  /// Ends the search, with counts from what it found.
  void finish(
    SearchOutcome outcome, {
    SearchProblem? problem,
    String? detail,
    int? filesSearched,
    SearchEngine engine = SearchEngine.ripgrep,
  }) {
    if (finished) {
      return;
    }
    final lines = _found.fold(0, (sum, file) => sum + file.lines.length);
    _updates.add(
      SearchFinished(
        SearchSummary(
          outcome: outcome,
          engine: engine,
          problem: problem,
          detail: detail,
          filesSearched: filesSearched ?? _found.length,
          filesMatched: _found.length,
          lines: lines,
          matches: _found.fold(0, (sum, file) => sum + file.matches),
        ),
      ),
    );
    unawaited(_updates.close());
  }

  @override
  Future<void> cancel() async {
    cancelRequested = true;
    finish(SearchOutcome.cancelled);
  }
}

/// A file with one matching line per entry of [lines]: (line, text, match).
SearchFileResult searchFile(
  String path,
  List<(int, String, String)> lines,
) => SearchFileResult(
  path: path,
  lines: [
    for (final (number, text, match) in lines)
      SearchLine(
        line: number,
        column: text.indexOf(match) + 1,
        preview: text,
        ranges: [text.indexOf(match), text.indexOf(match) + match.length],
      ),
  ],
);
